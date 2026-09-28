import AgentRunKit
import Foundation

/// A JSON-RPC 2.0 transport for LSP servers. LSP frames messages with `Content-Length` headers
/// (the Base Protocol), unlike `StdioMCPTransport` (Vendor/AgentRunKit), which uses
/// newline-delimited JSON — that framing is incompatible here, so this is a separate transport
/// rather than a reuse of the vendored MCP client. Unlike `MCPClient`, this transport does not
/// silently drop server-initiated notifications: `sourcekit-lsp` pushes `textDocument/publishDiagnostics`
/// unsolicited, and the owner needs those to arrive via `onNotification`.
actor LSPStdioTransport {
    enum TransportError: Error { case notRunning, launchFailed(Error), timeout }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var timeoutTasks: [JSONRPCID: Task<Void, Never>] = [:]
    private var nextRequestID = 0
    private var onNotification: (@Sendable (JSONRPCNotification) -> Void)?

    func start(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL,
        onNotification: @escaping @Sendable (JSONRPCNotification) -> Void
    ) throws {
        guard process == nil else { return }
        self.onNotification = onNotification
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Never read stderr; route it to /dev/null so a chatty server cannot fill the pipe buffer
        // and block on writes.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TransportError.launchFailed(error)
        }
        self.process = process
        stdinHandle = stdin.fileHandleForWriting
        let readHandle = stdout.fileHandleForReading
        stdoutHandle = readHandle
        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Task { await self?.consume(chunk) }
        }
    }

    func sendRequest(method: String, params: JSONValue? = nil, timeout: TimeInterval = 15) async throws -> JSONRPCResponse {
        guard process != nil else { throw TransportError.notRunning }
        let id = JSONRPCID.int(nextRequestID)
        nextRequestID += 1
        try write(JSONRPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.failPending(id, with: TransportError.timeout)
            }
        }
    }

    func sendNotification(method: String, params: JSONValue? = nil) throws {
        try write(JSONRPCNotification(method: method, params: params))
    }

    func shutdown() async {
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        for id in Array(pendingRequests.keys) { failPending(id, with: TransportError.notRunning) }
        guard let process, process.isRunning else {
            self.process = nil
            stdinHandle = nil
            return
        }
        stdinHandle?.closeFile()
        stdinHandle = nil
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        self.process = nil
    }

    private func failPending(_ id: JSONRPCID, with error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func resolvePending(_ id: JSONRPCID, with response: JSONRPCResponse) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(returning: response)
    }

    private func write(_ message: some Encodable) throws {
        try writeRaw(try JSONEncoder().encode(message))
    }

    private func writeRaw(_ body: Data) throws {
        guard let stdinHandle else { throw TransportError.notRunning }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try stdinHandle.write(contentsOf: framed)
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let message = extractMessage() { dispatch(message) }
    }

    /// Parses one `Content-Length: N\r\n\r\n<N bytes>` frame off the front of `buffer`, if a
    /// complete one is available yet.
    private func extractMessage() -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        guard let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var contentLength: Int?
        for line in headerString.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        guard let length = contentLength,
              let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: length, limitedBy: buffer.endIndex) else { return nil }
        let body = Data(buffer[headerEnd.upperBound..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }

    private func dispatch(_ data: Data) {
        guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
        switch message {
        case let .response(response):
            guard let id = response.id else { return }
            resolvePending(id, with: response)
        case let .notification(notification):
            onNotification?(notification)
        case let .request(request):
            // A server-initiated request (e.g. workspace/configuration). This minimal client does
            // not support them; reply so the server does not hang waiting for a response.
            // `JSONRPCErrorObject` has no public initializer outside AgentRunKit, so this one
            // response is built as raw JSON instead of the typed model.
            let idJSON = (try? JSONEncoder().encode(request.id)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            let raw = Data("{\"jsonrpc\":\"2.0\",\"id\":\(idJSON),\"error\":{\"code\":-32601,\"message\":\"Method not supported by this client\"}}".utf8)
            try? writeRaw(raw)
        }
    }
}
