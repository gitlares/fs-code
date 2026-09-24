@preconcurrency import Foundation
import CoreFoundation
import Darwin

/// A bounded JSON-RPC transport for `codex app-server --stdio`.
/// Protocol messages and stderr are never logged because they may contain credentials.
final class CodexRuntime: @unchecked Sendable {
    typealias JSONObject = [String: Any]
    typealias Factory = @Sendable (URL, URL) throws -> CodexRuntime

    enum RuntimeError: Error, Equatable {
        case unavailable
        case terminated
        case malformed
        case timedOut
        case remote(code: Int)
    }

    struct Notification: @unchecked Sendable {
        let method: String
        let params: JSONObject
    }

    struct Response: @unchecked Sendable {
        let object: JSONObject
    }

    struct DynamicToolCall: Sendable {
        let requestID: AgentRPCRequestID
        let threadID: String
        let turnID: String
        let callID: String
        let namespace: String?
        let toolName: String
        let arguments: AgentJSONValue
    }

    typealias DynamicToolHandler = @Sendable (DynamicToolCall) async -> AgentDynamicToolResult

    private final class PendingDynamicCall: @unchecked Sendable {
        let transportID: UUID
        let requestID: AgentRPCRequestID
        var task: Task<Void, Never>?

        init(transportID: UUID, requestID: AgentRPCRequestID) {
            self.transportID = transportID
            self.requestID = requestID
        }
    }

    private enum RequestRegistration {
        case ready(input: FileHandle, transportID: UUID)
        case cancelled
        case unavailable
    }

    struct Parameters: @unchecked Sendable, ExpressibleByDictionaryLiteral {
        private(set) var object: JSONObject

        init(dictionaryLiteral elements: (String, Any)...) {
            object = Dictionary(uniqueKeysWithValues: elements)
        }

        init(_ object: JSONObject) {
            self.object = object
        }

        subscript(key: String) -> Any? {
            get { object[key] }
            set { object[key] = newValue }
        }
    }

    static let live: Factory = { executable, home in
        CodexRuntime(executable: executable, home: home)
    }

    private let executable: URL
    private let home: URL
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.fscode.codex-runtime.write", qos: .userInitiated)
    private let maximumMessageBytes = 1_048_576

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var nextID = 0
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Response, Error>] = [:]
    private var preparing = Set<Int>()
    private var cancelledBeforeRegistration = Set<Int>()
    private var transportID: UUID?
    private var pendingDynamicCalls: [UUID: PendingDynamicCall] = [:]

    private var notificationHandler: (@Sendable (Notification) -> Void)?
    private var terminationHandler: (@Sendable (RuntimeError) -> Void)?
    private var dynamicToolHandler: DynamicToolHandler?

    var onNotification: (@Sendable (Notification) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return notificationHandler
        }
        set {
            lock.lock()
            notificationHandler = newValue
            lock.unlock()
        }
    }

    var onTermination: (@Sendable (RuntimeError) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return terminationHandler
        }
        set {
            lock.lock()
            terminationHandler = newValue
            lock.unlock()
        }
    }

    var onDynamicToolCall: DynamicToolHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return dynamicToolHandler
        }
        set {
            lock.lock()
            dynamicToolHandler = newValue
            lock.unlock()
        }
    }

    init(executable: URL, home: URL, requestTimeout: TimeInterval = 30) {
        self.executable = executable
        self.home = home
        self.requestTimeout = requestTimeout
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimeError.unavailable
        }

        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "app-server",
            "--stdio",
            "-c",
            "cli_auth_credentials_store=\"keyring\""
        ]
        child.currentDirectoryURL = home
        child.environment = Self.childEnvironment(codexHome: home)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading

        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                self?.processTerminated(child)
                return
            }
            self?.receive(data)
        }
        stderr.readabilityHandler = { handle in
            // Drain without retaining or exposing potentially sensitive output.
            _ = handle.availableData
        }
        child.terminationHandler = { [weak self] _ in
            self?.processTerminated(child)
        }

        process = child
        transportID = UUID()
        input = stdinPipe.fileHandleForWriting
        output = stdout
        errorOutput = stderr
        buffer.removeAll(keepingCapacity: true)

        do {
            try child.run()
        } catch {
            teardownLocked(matching: child)
            throw error
        }
    }

    func request(method: String, params: Parameters) async throws -> Response {
        let id = makeRequestID()

        let message: Data
        do {
            message = try Self.encode([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params.object
            ])
        } catch {
            throw RuntimeError.malformed
        }
        guard message.count + 1 <= maximumMessageBytes else {
            throw RuntimeError.malformed
        }

        prepareRequest(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                switch registerRequest(id: id, continuation: continuation) {
                case .ready(let input, let transportID):
                    enqueueWrite(
                        message,
                        input: input,
                        transportID: transportID,
                        pendingRequestID: id
                    )
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + requestTimeout
                    ) { [weak self] in
                        self?.timeoutRequest(id)
                    }
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .unavailable:
                    continuation.resume(throwing: RuntimeError.unavailable)
                }
            }
        } onCancel: {
            cancelRequest(id)
        }
    }

    func notify(method: String, params: JSONObject) throws {
        let message: Data
        do {
            message = try Self.encode([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        } catch {
            throw RuntimeError.malformed
        }
        guard message.count + 1 <= maximumMessageBytes else {
            throw RuntimeError.malformed
        }

        lock.lock()
        guard let input, let transportID, process?.isRunning == true else {
            lock.unlock()
            throw RuntimeError.unavailable
        }
        lock.unlock()
        enqueueWrite(message, input: input, transportID: transportID, pendingRequestID: nil)
    }

    func stop() {
        let (child, continuations) = detachTransport(notifyTermination: false)

        complete(continuations, with: .failure(RuntimeError.terminated))
        guard let child else { return }
        Self.terminateAndReapInBackground(child)
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        var overflow = false

        lock.lock()
        guard process != nil else {
            lock.unlock()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        if buffer.count > 1_048_576 || lines.contains(where: { $0.count > 1_048_576 }) {
            overflow = true
        }
        lock.unlock()

        if overflow {
            failTransport(.malformed)
            return
        }

        // Keep JSON decoding outside the transport lock and MainActor callers.
        for line in lines where !line.isEmpty {
            guard
                let value = try? JSONSerialization.jsonObject(with: line),
                let object = value as? JSONObject
            else {
                failTransport(.malformed)
                return
            }
            route(object)
        }
    }

    private func route(_ object: JSONObject) {
        if let method = object["method"] as? String, object["id"] != nil {
            routeServerRequest(method: method, id: object["id"]!, params: object["params"])
            return
        }
        if let id = Self.integerID(object["id"]) {
            let continuation: CheckedContinuation<Response, Error>
            let responseResult: Result<Response, Error>
            lock.lock()
            guard let registered = pending.removeValue(forKey: id) else {
                lock.unlock()
                return
            }
            continuation = registered
            if let result = object["result"] as? JSONObject {
                responseResult = .success(Response(object: result))
            } else if let error = object["error"] as? JSONObject {
                let code = (error["code"] as? NSNumber)?.intValue ?? -1
                responseResult = .failure(RuntimeError.remote(code: code))
            } else {
                responseResult = .failure(RuntimeError.malformed)
            }
            lock.unlock()
            continuation.resume(with: responseResult)
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? JSONObject ?? [:]
        let handler = onNotification
        handler?(Notification(method: method, params: params))
    }

    private func cancelRequest(_ id: Int) {
        let continuation: CheckedContinuation<Response, Error>?
        lock.lock()
        continuation = pending.removeValue(forKey: id)
        if continuation == nil, preparing.remove(id) != nil {
            cancelledBeforeRegistration.insert(id)
        }
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(throwing: CancellationError())
        failTransport(.terminated)
    }

    private func timeoutRequest(_ id: Int) {
        let continuation: CheckedContinuation<Response, Error>?
        lock.lock()
        continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(throwing: RuntimeError.timedOut)
        failTransport(.timedOut)
    }

    private func processTerminated(_ terminatedProcess: Process) {
        let continuations: [CheckedContinuation<Response, Error>]
        let handler: (@Sendable (RuntimeError) -> Void)?
        lock.lock()
        guard process === terminatedProcess else {
            lock.unlock()
            return
        }
        handler = terminationHandler
        continuations = teardownLocked(matching: terminatedProcess)
        lock.unlock()
        complete(continuations, with: .failure(RuntimeError.terminated))
        handler?(.terminated)
        Self.terminateAndReapInBackground(terminatedProcess)
    }

    private func failTransport(_ error: RuntimeError) {
        let child: Process?
        let continuations: [CheckedContinuation<Response, Error>]
        let handler: (@Sendable (RuntimeError) -> Void)?

        lock.lock()
        child = process
        handler = terminationHandler
        continuations = teardownLocked(matching: child)
        lock.unlock()

        complete(continuations, with: .failure(error))
        handler?(error)
        if let child { Self.terminateAndReapInBackground(child) }
    }

    @discardableResult
    private func teardownLocked(
        matching expectedProcess: Process?
    ) -> [CheckedContinuation<Response, Error>] {
        if let expectedProcess, process !== expectedProcess { return [] }

        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()

        process = nil
        transportID = nil
        input = nil
        output = nil
        errorOutput = nil
        notificationHandler = nil
        terminationHandler = nil
        dynamicToolHandler = nil
        buffer.removeAll(keepingCapacity: false)
        preparing.removeAll()
        cancelledBeforeRegistration.removeAll()
        let continuations = Array(pending.values)
        pending.removeAll()
        let dynamicTasks = pendingDynamicCalls.values.compactMap(\.task)
        pendingDynamicCalls.removeAll()
        for task in dynamicTasks { task.cancel() }
        return continuations
    }

    private func complete(
        _ continuations: [CheckedContinuation<Response, Error>],
        with result: Result<Response, Error>
    ) {
        for continuation in continuations { continuation.resume(with: result) }
    }

    private func enqueueWrite(
        _ message: Data,
        input: FileHandle,
        transportID expectedTransportID: UUID,
        pendingRequestID: Int?
    ) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let isCurrent = transportID == expectedTransportID
                && self.input === input
                && process?.isRunning == true
                && (pendingRequestID.map { pending[$0] != nil } ?? true)
            lock.unlock()
            guard isCurrent else { return }

            do {
                try input.write(contentsOf: message)
                try input.write(contentsOf: Data([0x0A]))
            } catch {
                failTransport(.terminated)
            }
        }
    }

    private func routeServerRequest(method: String, id: Any, params: Any?) {
        if method == "item/tool/call" {
            routeDynamicToolCall(id: id, params: params)
            return
        }

        let response: JSONObject
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            response = ["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]]
        case "execCommandApproval", "applyPatchApproval":
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "decision": [
                        "denied": ["rejection": "FS Code is operating in read-only mode."]
                    ]
                ]
            ]
        default:
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Unsupported server request"]
            ]
        }

        writeServerResponse(response)
    }

    private func routeDynamicToolCall(id: Any, params: Any?) {
        guard let requestID = Self.serverRequestID(id),
              let params = params as? JSONObject,
              let threadID = params["threadId"] as? String, !threadID.isEmpty,
              let turnID = params["turnId"] as? String, !turnID.isEmpty,
              let callID = params["callId"] as? String, !callID.isEmpty,
              let toolName = params["tool"] as? String, !toolName.isEmpty,
              let rawArguments = params["arguments"],
              let arguments = AgentJSONValue(jsonObject: rawArguments) else {
            writeServerError(id: id, code: -32602, message: "Invalid dynamic tool request")
            return
        }

        let handler: DynamicToolHandler
        let activeTransportID: UUID
        let invocationID = UUID()
        let pendingCall: PendingDynamicCall
        lock.lock()
        guard let registered = dynamicToolHandler,
              let currentTransportID = transportID,
              process?.isRunning == true else {
            lock.unlock()
            writeServerResponse([
                "jsonrpc": "2.0",
                "id": Self.jsonObject(for: requestID),
                "result": [
                    "success": false,
                    "contentItems": [[
                        "type": "inputText",
                        "text": "The project tool handler is unavailable."
                    ]]
                ]
            ])
            return
        }
        handler = registered
        activeTransportID = currentTransportID
        pendingCall = PendingDynamicCall(
            transportID: currentTransportID,
            requestID: requestID
        )
        pendingDynamicCalls[invocationID] = pendingCall
        lock.unlock()

        let call = DynamicToolCall(
            requestID: requestID,
            threadID: threadID,
            turnID: turnID,
            callID: callID,
            namespace: params["namespace"] as? String,
            toolName: toolName,
            arguments: arguments
        )
        let task = Task { [weak self, weak pendingCall] in
            let result = await handler(call)
            guard !Task.isCancelled, let self, let pendingCall else { return }
            respondToDynamicToolCall(
                requestID: requestID,
                invocationID: invocationID,
                pendingCall: pendingCall,
                expectedTransportID: activeTransportID,
                result: result
            )
        }
        lock.lock()
        if pendingDynamicCalls[invocationID] === pendingCall {
            pendingCall.task = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func respondToDynamicToolCall(
        requestID: AgentRPCRequestID,
        invocationID: UUID,
        pendingCall: PendingDynamicCall,
        expectedTransportID: UUID,
        result: AgentDynamicToolResult
    ) {
        lock.lock()
        guard pendingDynamicCalls[invocationID] === pendingCall,
              pendingCall.transportID == expectedTransportID,
              transportID == expectedTransportID,
              process?.isRunning == true else {
            lock.unlock()
            return
        }
        pendingDynamicCalls.removeValue(forKey: invocationID)
        lock.unlock()

        writeServerResponse([
            "jsonrpc": "2.0",
            "id": Self.jsonObject(for: requestID),
            "result": [
                "success": result.success,
                "contentItems": [["type": "inputText", "text": result.message]]
            ]
        ], expectedTransportID: expectedTransportID)
    }

    func cancelDynamicToolCalls() {
        let calls: [PendingDynamicCall]
        lock.lock()
        calls = Array(pendingDynamicCalls.values)
        pendingDynamicCalls.removeAll()
        lock.unlock()
        for call in calls {
            call.task?.cancel()
            writeServerResponse([
                "jsonrpc": "2.0",
                "id": Self.jsonObject(for: call.requestID),
                "result": [
                    "success": false,
                    "contentItems": [[
                        "type": "inputText",
                        "text": "The project tool request was cancelled."
                    ]]
                ]
            ], expectedTransportID: call.transportID)
        }
    }

    private func writeServerError(id: Any, code: Int, message: String) {
        writeServerResponse([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ])
    }

    private func writeServerResponse(
        _ response: JSONObject,
        expectedTransportID: UUID? = nil
    ) {
        guard let data = try? Self.encode(response), data.count + 1 <= maximumMessageBytes else {
            failTransport(.malformed)
            return
        }
        lock.lock()
        guard let input, let currentTransportID = transportID,
              expectedTransportID == nil || expectedTransportID == currentTransportID,
              process?.isRunning == true else {
            lock.unlock()
            return
        }
        lock.unlock()
        enqueueWrite(data, input: input, transportID: currentTransportID, pendingRequestID: nil)
    }

    private func makeRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func prepareRequest(_ id: Int) {
        lock.lock()
        preparing.insert(id)
        lock.unlock()
    }

    private func registerRequest(
        id: Int,
        continuation: CheckedContinuation<Response, Error>
    ) -> RequestRegistration {
        lock.lock()
        defer { lock.unlock() }
        preparing.remove(id)
        if cancelledBeforeRegistration.remove(id) != nil {
            return .cancelled
        }
        guard let input, let transportID, process?.isRunning == true else {
            return .unavailable
        }
        pending[id] = continuation
        return .ready(input: input, transportID: transportID)
    }

    private func detachTransport(
        notifyTermination: Bool
    ) -> (Process?, [CheckedContinuation<Response, Error>]) {
        lock.lock()
        defer { lock.unlock() }
        let child = process
        if !notifyTermination { terminationHandler = nil }
        return (child, teardownLocked(matching: child))
    }

    private static func terminateAndReapInBackground(_ process: Process) {
        DispatchQueue.global(qos: .utility).async {
            terminateAndReapBlocking(process)
        }
    }

    private static func terminateAndReapBlocking(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func encode(_ object: JSONObject) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RuntimeError.malformed
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let id = value as? Int { return id }
        return (value as? NSNumber)?.intValue
    }

    private static func serverRequestID(_ value: Any) -> AgentRPCRequestID? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let integer = value.int64Value
            guard Decimal(integer) == value.decimalValue else { return nil }
            return .integer(integer)
        }
        return nil
    }

    private static func jsonObject(for requestID: AgentRPCRequestID) -> Any {
        switch requestID {
        case .string(let value): value
        case .integer(let value): value
        }
    }

    private static func childEnvironment(codexHome: URL) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SYSTEMROOT"]
        var environment = Dictionary(
            uniqueKeysWithValues: allowed.compactMap { key in
                parent[key].map { (key, $0) }
            }
        )
        environment["CODEX_HOME"] = codexHome.path
        return environment
    }
}
