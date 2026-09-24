import AgentRunKit
import Foundation

/// Stateless AgentRunKit provider adapter with FS-owned turn identity and injection boundaries.
/// It deliberately does not use `Agent`: FS must acknowledge `turn/steer` without cancelling a
/// response, and it must retain ownership of every tool invocation.
@MainActor
final class NativeAgentRuntime: AgentEngine {
    struct Configuration: Sendable {
        let projectID: UUID
        let projectRoot: URL
        let profileID: UUID
        let sessionID: UUID
        let modelID: String?
        let effort: String?
        let historyRoot: URL?

        init(projectID: UUID, projectRoot: URL, profileID: UUID, sessionID: UUID, modelID: String?, effort: String?, historyRoot: URL? = nil) {
            self.projectID = projectID
            self.projectRoot = projectRoot
            self.profileID = profileID
            self.sessionID = sessionID
            self.modelID = modelID
            self.effort = effort
            self.historyRoot = historyRoot
        }
    }

    typealias ClientFactory = @MainActor @Sendable (Configuration) async throws -> any LLMClient
    typealias NotificationHandler = AgentEngine.NotificationHandler
    typealias DynamicToolHandler = @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult

    enum RuntimeError: Error, Sendable {
        case unavailable
        case malformed
        case streamDidNotFinish
        case streamTerminationInvalid
        case unknownThread
        case unknownTurn
    }

    private struct Run {
        let id: String
        let threadID: String
        var messages: [ChatMessage]
        var pendingSteers: [String]
        let modelID: String?
        let effort: String?
        let mode: AgentMode
        let selectedPlanID: String?
        let hostMetadata: String
        var toolOperations: Int
        var task: Task<Void, Never>?
    }

    let configuration: Configuration
    private let makeClient: ClientFactory
    private let projectTools: NativeProjectTools
    private let dynamicToolHandler: DynamicToolHandler?
    private let historyStore: NativeAgentHistoryStore
    private var threads: [String: [ChatMessage]] = [:]
    private var threadModes: [String: AgentMode] = [:]
    private var selectedPlans: [String: String] = [:]
    private var threadHostMetadata: [String: String] = [:]
    private var runs: [String: Run] = [:]
    private var steeredMessageIDs = Set<String>()
    private var notificationHandler: NotificationHandler?

    init(
        configuration: Configuration,
        makeClient: @escaping ClientFactory,
        dynamicToolHandler: DynamicToolHandler? = nil
    ) {
        self.configuration = configuration
        self.makeClient = makeClient
        projectTools = NativeProjectTools(rootURL: configuration.projectRoot)
        self.dynamicToolHandler = dynamicToolHandler
        historyStore = NativeAgentHistoryStore(projectID: configuration.projectID, profileID: configuration.profileID, rootOverride: configuration.historyRoot)
    }

    var onNotification: NotificationHandler? {
        get { notificationHandler }
        set { notificationHandler = newValue }
    }

    func stop() {
        for (_, run) in runs { run.task?.cancel() }
        runs.removeAll()
    }

    /// RPC-compatible compatibility surface used while `AgentConversationTransport` migrates.
    /// Native threads are local durable identifiers; provider calls are stateless (`store: false`).
    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "thread/start":
            let id = UUID().uuidString
            threads[id] = Self.baseline(from: params)
            threadModes[id] = try Self.mode(from: params)
            selectedPlans[id] = params["selectedPlanID"] as? String
            threadHostMetadata[id] = params["hostMetadata"] as? String ?? ""
            try historyStore.save(threadID: id, messages: threads[id] ?? [])
            return ["thread": ["id": id], "executionPolicy": "hostTools", "sandbox": ["type": "hostTools", "networkAccess": false]]
        case "thread/resume":
            guard let id = params["threadId"] as? String else { throw RuntimeError.malformed }
            if threads[id] == nil { threads[id] = try historyStore.load(threadID: id) ?? Self.baseline(from: params) }
            threadModes[id] = try Self.mode(from: params)
            selectedPlans[id] = params["selectedPlanID"] as? String
            threadHostMetadata[id] = params["hostMetadata"] as? String ?? ""
            threads[id] = Self.refreshInstructions(in: threads[id] ?? [], from: params)
            try historyStore.save(threadID: id, messages: threads[id] ?? [])
            return ["thread": ["id": id], "executionPolicy": "hostTools", "sandbox": ["type": "hostTools", "networkAccess": false]]
        case "turn/start":
            guard let threadID = params["threadId"] as? String,
                  let input = Self.inputText(from: params),
                  var history = threads[threadID] else { throw RuntimeError.malformed }
            guard !runs.values.contains(where: { $0.threadID == threadID }) else { throw RuntimeError.unavailable }
            let turnID = UUID().uuidString
            history.append(.user(input))
            threads[threadID] = history
            try historyStore.save(threadID: threadID, messages: history)
            var run = Run(
                id: turnID,
                threadID: threadID,
                messages: history,
                pendingSteers: [],
                modelID: params["model"] as? String ?? configuration.modelID,
                effort: params["effort"] as? String ?? configuration.effort,
                mode: threadModes[threadID] ?? .build,
                selectedPlanID: selectedPlans[threadID],
                hostMetadata: threadHostMetadata[threadID] ?? "",
                toolOperations: 0,
                task: nil
            )
            run.task = Task { [weak self] in await self?.run(threadID: threadID, turnID: turnID) }
            runs[turnID] = run
            return ["turn": ["id": turnID]]
        case "turn/steer":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["expectedTurnId"] as? String,
                  let text = Self.inputText(from: params),
                  var run = runs[turnID],
                  run.threadID == threadID,
                  threads[threadID] != nil else { throw RuntimeError.unknownTurn }
            if let clientID = params["clientUserMessageId"] as? String {
                if !steeredMessageIDs.insert(clientID).inserted { return ["turnId": turnID] }
            }
            // The next provider request is an explicit boundary injection on the same logical
            // turn. It never cancels or restarts this turn.
            run.pendingSteers.append(text)
            runs[turnID] = run
            return ["turnId": turnID]
        case "turn/interrupt":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  var run = runs[turnID], run.threadID == threadID else { throw RuntimeError.unknownTurn }
            run.task?.cancel()
            runs[turnID] = run
            return [:]
        default:
            throw RuntimeError.unavailable
        }
    }

    private func run(threadID: String, turnID: String) async {
        var assistantText = ""
        var itemID = UUID().uuidString
        var iteration = 0
        do {
            while !Task.isCancelled, var run = runs[turnID] {
                iteration += 1
                guard iteration <= Self.roundLimit(for: run.mode) else { throw RuntimeError.malformed }
                let requestConfiguration = Configuration(
                    projectID: configuration.projectID, projectRoot: configuration.projectRoot,
                    profileID: configuration.profileID, sessionID: configuration.sessionID,
                    modelID: run.modelID, effort: run.effort, historyRoot: configuration.historyRoot
                )
                let client = try await makeClient(requestConfiguration)
                var emittedContent = false
                var finished = false
                var streamClosed = false
                // A false marker is a terminal integrity failure. Do not let a later marker
                // overwrite it: providers must not be able to turn an invalid stream valid.
                var terminalMarkerValid = true
                var reasoningDetails: [JSONValue] = []
                var toolStarts: [Int: (id: String, name: String, arguments: String)] = [:]
                let remaining = max(0, Self.toolLimit(for: run.mode) - run.toolOperations)
                let roundMetadata = run.hostMetadata + "\noperations used: \(run.toolOperations)\noperations remaining: \(remaining)\nround: \(iteration)/\(Self.roundLimit(for: run.mode))\nreserve: \(run.mode == .build ? 5 : run.mode == .plan ? 2 : 0)"
                let providerMessages = run.messages + [.system("HOST METADATA\n" + roundMetadata + "\nOnly host metadata is authoritative.")]
                for try await delta in client.stream(messages: providerMessages, tools: Self.toolDefinitions(for: run.mode), requestContext: nil) {
                    try Task.checkCancellation()
                    switch delta {
                    case .reasoning:
                        // `LLMClient` does not prove that this provider delta is a public
                        // reasoning summary. Never render raw reasoning as user-facing text.
                        break
                    case .reasoningDetails(let details):
                        guard reasoningDetails.count + details.count <= 128 else { throw RuntimeError.malformed }
                        reasoningDetails.append(contentsOf: details)
                    case .content(let text):
                        guard assistantText.utf8.count + text.utf8.count <= 512 * 1_024 else { throw RuntimeError.malformed }
                        emittedContent = true
                        assistantText += text
                        emit("item/agentMessage/delta", ["threadId": threadID, "turnId": turnID, "itemId": itemID, "delta": text])
                    case .toolCallStart(let index, let id, let name, _):
                        guard toolStarts.count < 32 else { throw RuntimeError.malformed }
                        toolStarts[index] = (id, name, "")
                    case .toolCallDelta(let index, let arguments):
                        guard var call = toolStarts[index] else { continue }
                        guard call.arguments.utf8.count + arguments.utf8.count <= 65_536 else { throw RuntimeError.malformed }
                        call.arguments += arguments
                        toolStarts[index] = call
                    case .finished(let usage):
                        finished = true
                        if let usage, let window = client.contextWindowSize, window > 0 {
                            emit("thread/tokenUsage/updated", ["threadId": threadID, "turnId": turnID, "tokenUsage": ["last": ["inputTokens": usage.input], "modelContextWindow": window]])
                        }
                    case .streamClosed(let seen):
                        streamClosed = true
                        terminalMarkerValid = terminalMarkerValid && seen
                    default:
                        break
                    }
                }
                guard finished else { throw RuntimeError.streamDidNotFinish }
                // Responses API v6 establishes successful completion with its terminal
                // `response.completed` event, which is forwarded as `.finished` and then
                // normal stream exhaustion. It intentionally does not emit `.streamClosed`.
                // Other clients retain the explicit close-marker requirement.
                guard !streamClosed || terminalMarkerValid else {
                    throw RuntimeError.streamTerminationInvalid
                }
                guard client.providerIdentifier == .openAIResponses || streamClosed else {
                    throw RuntimeError.streamTerminationInvalid
                }
                guard var latest = runs[turnID] else { return }
                let toolCalls = try toolStarts.keys.sorted().map { index -> ToolCall in
                    guard let call = toolStarts[index], !call.name.isEmpty, !call.arguments.isEmpty else { throw RuntimeError.malformed }
                    return ToolCall(id: call.id, name: call.name, arguments: call.arguments)
                }
                if !toolCalls.isEmpty {
                    guard finished else { throw RuntimeError.malformed }
                    latest.messages.append(.assistant(AssistantMessage(content: assistantText, toolCalls: toolCalls, reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails)))
                    runs[turnID] = latest
                    threads[threadID] = latest.messages
                    try historyStore.save(threadID: threadID, messages: latest.messages)
                    for call in toolCalls {
                        guard var budgeted = runs[turnID] else { return }
                        guard budgeted.toolOperations < Self.toolLimit(for: budgeted.mode) else { throw RuntimeError.malformed }
                        let reserve = budgeted.mode == .build ? 5 : budgeted.mode == .plan ? 2 : 0
                        if budgeted.toolOperations >= Self.toolLimit(for: budgeted.mode) - reserve,
                           !Self.isClosingTool(call.name, in: budgeted.mode) {
                            let result = "The host budget reserve is active. New implementation or investigation operations are unavailable."
                            budgeted.messages.append(.tool(id: call.id, name: call.name, content: result))
                            runs[turnID] = budgeted
                            threads[threadID] = budgeted.messages
                            try historyStore.save(threadID: threadID, messages: budgeted.messages)
                            continue
                        }
                        budgeted.toolOperations += 1
                        runs[turnID] = budgeted
                        try Task.checkCancellation()
                        let result = await execute(call, mode: run.mode, selectedPlanID: run.selectedPlanID, threadID: threadID, turnID: turnID)
                        try Task.checkCancellation()
                        guard var current = runs[turnID] else { return }
                        current.messages.append(.tool(id: call.id, name: call.name, content: result))
                        runs[turnID] = current
                        threads[threadID] = current.messages
                        try historyStore.save(threadID: threadID, messages: current.messages)
                    }
                    guard var current = runs[turnID] else { return }
                    while !current.pendingSteers.isEmpty { current.messages.append(.user(current.pendingSteers.removeFirst())) }
                    runs[turnID] = current
                    threads[threadID] = current.messages
                    try historyStore.save(threadID: threadID, messages: current.messages)
                    assistantText = ""
                    itemID = UUID().uuidString
                    continue
                }
                if emittedContent {
                    latest.messages.append(.assistant(AssistantMessage(content: assistantText, reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails)))
                    threads[threadID] = latest.messages
                    try historyStore.save(threadID: threadID, messages: latest.messages)
                }
                if latest.pendingSteers.isEmpty {
                    runs.removeValue(forKey: turnID)
                    emit("item/completed", ["threadId": threadID, "turnId": turnID, "item": ["id": itemID, "type": "agentMessage", "phase": "final_answer", "text": assistantText]])
                    emit("turn/completed", ["threadId": threadID, "turn": ["id": turnID, "status": "completed", "items": []]])
                    return
                }
                let steer = latest.pendingSteers.removeFirst()
                latest.messages.append(.user(steer))
                runs[turnID] = latest
                threads[threadID] = latest.messages
                try historyStore.save(threadID: threadID, messages: latest.messages)
                assistantText = ""
                itemID = UUID().uuidString
            }
            if runs.removeValue(forKey: turnID) != nil {
                emit("turn/completed", ["threadId": threadID, "turn": ["id": turnID, "status": "interrupted", "items": []]])
            }
        } catch {
            guard !Task.isCancelled else {
                if runs.removeValue(forKey: turnID) != nil {
                    emit("turn/completed", ["threadId": threadID, "turn": ["id": turnID, "status": "interrupted", "items": []]])
                }
                return
            }
            runs.removeValue(forKey: turnID)
            emit("error", ["threadId": threadID, "turnId": turnID, "error": ["message": Self.safeFailureMessage(error)]])
        }
    }

    private static func safeFailureMessage(_ error: Error) -> String {
        let category: String
        if let failure = error as? RuntimeError {
            switch failure {
            case .streamDidNotFinish: category = "missing-finish"
            case .streamTerminationInvalid: category = "invalid-stream-close"
            default: category = "runtime-validation"
            }
        } else if case let AgentError.llmError(transport) = error {
            switch transport {
            case .streamFailed(let stream):
                switch stream {
                case .malformedStream(let reason, _):
                    switch reason {
                    case .finalizedSemanticStateDiverged: category = "stream-state-mismatch"
                    case .finalizedFieldDiverged(let field):
                        let allowed = ["reasoning", "reasoning-details", "content", "content-empty", "tool-indices", "tool-arguments"]
                        category = allowed.contains(field) ? "stream-mismatch-" + field : "stream-state-mismatch"
                    case .conflictingAssistantContinuity: category = "stream-continuity-mismatch"
                    default: category = "malformed-tool-stream"
                    }
                case .idleTimeout: category = "stream-timeout"
                case .providerTerminationMissing: category = "provider-finish-missing"
                case .finishedDeltaMissing: category = "sdk-finish-missing"
                case .midStreamTransportFailure: category = "connection-interrupted"
                case .providerError: category = "provider-error"
                }
            case .decodingFailed: category = "response-decoding"
            case .httpError(let status, _): category = "http-\(status)"
            case .rateLimited: category = "rate-limited"
            default: category = "provider-transport"
            }
        } else if error is CocoaError { category = "local-history" }
        else { category = "unexpected-error" }
        return "The response could not be completed (\(category))."
    }

    private func execute(_ call: ToolCall, mode: AgentMode, selectedPlanID: String?, threadID: String, turnID: String) async -> String {
        guard let data = call.arguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Tool arguments were invalid."
        }
        guard Self.isPermitted(call.name, in: mode) else {
            return "This tool is unavailable in \(mode.rawValue) mode. No file was changed."
        }
        if call.name == "fs_edit_file", let path = arguments["relative_path"] as? String,
           Self.isPlanPath(path) {
            return "Plan files may only be updated through the plan-status host capability."
        }
        if call.name == "fs_edit_file", let dynamicToolHandler,
           let value = AgentJSONValue(jsonObject: arguments) {
            let result = await dynamicToolHandler(AgentDynamicToolRequest(
                requestID: .string(call.id), profileID: configuration.profileID, sessionID: configuration.sessionID,
                threadID: threadID, turnID: turnID, callID: call.id, namespace: nil,
                toolName: call.name, arguments: value
            ))
            return result.message
        }
        guard let textArguments = arguments as? [String: String] else { return "Tool arguments were invalid." }
        return await projectTools.execute(name: call.name, arguments: textArguments, mode: mode, selectedPlanID: selectedPlanID)
    }

    private static let readToolDefinitions = [
        ToolDefinition(name: "read_project_file", description: "Read a UTF-8 project-relative file.", parametersSchema: .object(properties: ["relative_path": .string()], required: ["relative_path"])),
        ToolDefinition(name: "list_project_files", description: "List project-relative files.", parametersSchema: .object(properties: [:], required: [])),
        ToolDefinition(name: "search_project_text", description: "Search UTF-8 project files.", parametersSchema: .object(properties: ["query": .string()], required: ["query"]))
    ]

    private static let buildToolDefinitions = readToolDefinitions + [
        ToolDefinition(name: "fs_edit_file", description: "Apply one audited project-relative text replacement.", parametersSchema: .object(properties: [
            "relative_path": .string(), "old_text": .string(), "new_text": .string()
        ], required: ["relative_path", "old_text", "new_text"])),
        ToolDefinition(name: "fs_update_plan", description: "Update execution status for the host-selected approved plan.", parametersSchema: .object(properties: ["plan_id": .string(), "expected_revision": .string(), "markdown": .string()], required: ["plan_id", "expected_revision", "markdown"]))
    ]

    private static let planToolDefinitions = readToolDefinitions + [
        ToolDefinition(name: "fs_write_plan", description: "Write a draft Markdown plan under .fs/plans.", parametersSchema: .object(properties: [
            "relative_path": .string(), "content": .string()
        ], required: ["relative_path", "content"]))
    ]

    private static func toolDefinitions(for mode: AgentMode) -> [ToolDefinition] {
        switch mode { case .ask: readToolDefinitions; case .plan: planToolDefinitions; case .build: buildToolDefinitions }
    }

    private static func isPermitted(_ name: String, in mode: AgentMode) -> Bool {
        let read = ["read_project_file", "list_project_files", "search_project_text"]
        if read.contains(name) { return true }
        switch mode { case .build: return name == "fs_edit_file" || name == "fs_update_plan"; case .plan: return name == "fs_write_plan"; case .ask: return false }
    }

    private static func toolLimit(for mode: AgentMode) -> Int { switch mode { case .build: 40; case .plan: 15; case .ask: 4 } }
    private static func roundLimit(for mode: AgentMode) -> Int { switch mode { case .build: 16; case .plan: 8; case .ask: 4 } }
    private static func isClosingTool(_ name: String, in mode: AgentMode) -> Bool { name.hasPrefix("read_") || name == "fs_update_plan" || (mode == .plan && name == "fs_write_plan") }
    private static func isPlanPath(_ path: String) -> Bool { path.split(separator: "/").filter { $0 != "." }.joined(separator: "/").hasPrefix(".fs/plans/") }

    private func emit(_ method: String, _ params: [String: Any]) {
        notificationHandler?(method, params)
    }

    private static func inputText(from params: [String: Any]) -> String? {
        guard let input = params["input"] as? [[String: Any]],
              let first = input.first,
              first["type"] as? String == "text",
              let text = first["text"] as? String,
              !text.isEmpty else { return nil }
        return text
    }

    private static func refreshInstructions(in history: [ChatMessage], from params: [String: Any]) -> [ChatMessage] {
        let withoutSystem = history.filter {
            if case .system = $0 { return false }
            return true
        }
        guard let instructions = params["developerInstructions"] as? String, !instructions.isEmpty else { return withoutSystem }
        return [.system(instructions)] + withoutSystem
    }

    private static func baseline(from params: [String: Any]) -> [ChatMessage] {
        // Existing remote threads cannot be reconstructed with tool calls. A future migration
        // seeds this list only from sanitized local user/assistant history, never tool output.
        var messages: [ChatMessage] = []
        if let instructions = params["developerInstructions"] as? String, !instructions.isEmpty {
            messages.append(.system(instructions))
        }
        guard let seed = params["localHistory"] as? [[String: String]] else { return messages }
        messages.append(contentsOf: seed.compactMap { item in
            switch (item["role"], item["text"]) {
            case ("user", let text?): .user(text)
            case ("assistant", let text?): .assistant(AssistantMessage(content: text))
            default: nil
            }
        })
        return messages
    }

    private static func mode(from params: [String: Any]) throws -> AgentMode {
        guard let raw = params["agentMode"] as? String else { return .build }
        guard let mode = AgentMode(rawValue: raw) else { throw RuntimeError.malformed }
        return mode
    }

}
