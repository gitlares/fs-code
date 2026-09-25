import AgentRunKit
import Foundation
import XCTest
@testable import AgentConnectionCore

@MainActor
final class NativeAgentRuntimeTests: XCTestCase {
    func testStreamsFinalAndUsesSameTurnForSteerBoundary() async throws {
        let configuration = NativeAgentRuntime.Configuration(
            projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(),
            sessionID: UUID(), modelID: "test", effort: "medium"
        )
        let runtime = NativeAgentRuntime(configuration: configuration) { _ in
            ScriptedClient(script: [.content("First"), .finished(usage: nil)])
        }
        var events: [(String, [String: Any])] = []
        runtime.onNotification = { method, params in events.append((method, params)) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        let turn = try await runtime.request(method: "turn/start", params: [
            "threadId": threadID, "input": [["type": "text", "text": "Question"]]
        ])
        let turnID = try XCTUnwrap((turn["turn"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/steer", params: [
            "threadId": threadID, "expectedTurnId": turnID,
            "clientUserMessageId": "steer-1", "input": [["type": "text", "text": "Clarify"]]
        ])
        await waitUntil { events.contains { $0.0 == "turn/completed" } }
        XCTAssertEqual(events.filter { $0.0 == "item/agentMessage/delta" }.count, 2)
        let completed = try XCTUnwrap(events.last(where: { $0.0 == "turn/completed" })?.1["turn"] as? [String: Any])
        XCTAssertEqual(completed["id"] as? String, turnID)
        XCTAssertEqual(completed["status"] as? String, "completed")
    }

    func testIncompleteToolStreamNeverInvokesAuditedHandler() async throws {
        let configuration = NativeAgentRuntime.Configuration(
            projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(),
            sessionID: UUID(), modelID: "test", effort: nil
        )
        var handlerCalls = 0
        let runtime = NativeAgentRuntime(
            configuration: configuration,
            makeClient: { _ in
                ScriptedClient(script: [
                    .toolCallStart(index: 0, id: "edit", name: "fs_edit_file", kind: .function),
                    .toolCallDelta(index: 0, arguments: "{\"relative_path\":\"a.txt\",\"old_text\":\"\",\"new_text\":\"x\"}")
                ])
            },
            dynamicToolHandler: { _ in handlerCalls += 1; return .accepted("unexpected") }
        )
        var events: [String] = []
        runtime.onNotification = { method, _ in events.append(method) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Edit"]]])
        await waitUntil { events.contains("error") }
        XCTAssertEqual(handlerCalls, 0)
    }

    func testResponsesCompletedStreamWithoutCloseMarkerCompletes() async throws {
        let responseURL = URL(string: "https://responses-runtime-test.invalid/v1/responses")!
        let responseBody = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_test","status":"completed","summary":[{"type":"summary_text","text":"Plan"}],"encrypted_content":"provisional"}}

        data: {"type":"response.output_text.delta","delta":"Done"}

        data: {"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"reasoning","id":"rs_test","status":"completed","summary":[{"type":"summary_text","text":"Plan"}],"encrypted_content":"terminal"},{"type":"message","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":3,"output_tokens":1}}}

        """
        ResponsesRuntimeURLProtocol.install(url: responseURL, body: Data(responseBody.utf8))
        defer { ResponsesRuntimeURLProtocol.remove(url: responseURL) }
        let session = URLSession(configuration: ResponsesRuntimeURLProtocol.configuration())
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "test",
            baseURL: URL(string: "https://responses-runtime-test.invalid/v1/")!,
            session: session, store: false
        )
        let projectID = UUID()
        let profileID = UUID()
        let historyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: historyRoot) }
        let runtime = NativeAgentRuntime(
            configuration: .init(projectID: projectID, projectRoot: URL(fileURLWithPath: "/tmp"), profileID: profileID, sessionID: UUID(), modelID: "test", effort: nil, historyRoot: historyRoot),
            makeClient: { _ in client }
        )
        var events: [(String, [String: Any])] = []
        runtime.onNotification = { method, params in events.append((method, params)) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Question"]]])
        await waitUntil { events.contains { $0.0 == "turn/completed" || $0.0 == "error" } }
        XCTAssertTrue(events.contains { $0.0 == "turn/completed" })
        XCTAssertFalse(events.contains { $0.0 == "error" })
        XCTAssertEqual(events.filter { $0.0 == "item/agentMessage/delta" }.count, 1)
        let history = try XCTUnwrap(
            NativeAgentHistoryStore(projectID: projectID, profileID: profileID, rootOverride: historyRoot)
                .load(threadID: threadID)
        )
        let assistant = try XCTUnwrap(history.compactMap { message -> AssistantMessage? in
            if case let .assistant(value) = message { return value }
            return nil
        }.last)
        let details = try XCTUnwrap(assistant.reasoningDetails)
        XCTAssertEqual(details.count, 1)
        guard case let .object(fields) = try XCTUnwrap(details.first) else {
            return XCTFail("Expected the terminal reasoning detail.")
        }
        XCTAssertEqual(fields["status"], .string("completed"))
        XCTAssertEqual(fields["encrypted_content"], .string("terminal"))
    }

    func testResponsesLiteCompletedStreamReconstructsEmptyTerminalOutputFromDoneItems() async throws {
        let responseURL = URL(string: "https://responses-runtime-test.invalid/v1/responses")!
        let responseBody = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

        data: {"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[],"usage":{"input_tokens":3,"output_tokens":1}}}

        """
        ResponsesRuntimeURLProtocol.install(url: responseURL, body: Data(responseBody.utf8))
        defer { ResponsesRuntimeURLProtocol.remove(url: responseURL) }
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "test",
            baseURL: URL(string: "https://responses-runtime-test.invalid/v1/")!,
            session: URLSession(configuration: ResponsesRuntimeURLProtocol.configuration()), store: false
        )
        let runtime = NativeAgentRuntime(
            configuration: .init(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil),
            makeClient: { _ in client }
        )
        var events: [(String, [String: Any])] = []
        runtime.onNotification = { method, params in events.append((method, params)) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Question"]]])
        await waitUntil { events.contains { $0.0 == "turn/completed" || $0.0 == "error" } }
        XCTAssertTrue(events.contains { $0.0 == "turn/completed" })
        XCTAssertFalse(events.contains { $0.0 == "error" })
        let delta = try XCTUnwrap(events.last(where: { $0.0 == "item/agentMessage/delta" })?.1["delta"] as? String)
        XCTAssertEqual(delta, "Recovered")
    }

    func testResponsesCompletedStreamRejectsDivergentTerminalContent() async throws {
        let responseURL = URL(string: "https://responses-runtime-test.invalid/v1/responses")!
        let responseBody = """
        data: {"type":"response.output_text.delta","delta":"Streamed"}

        data: {"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Terminal"}]}]}}

        """
        ResponsesRuntimeURLProtocol.install(url: responseURL, body: Data(responseBody.utf8))
        defer { ResponsesRuntimeURLProtocol.remove(url: responseURL) }
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "test",
            baseURL: URL(string: "https://responses-runtime-test.invalid/v1/")!,
            session: URLSession(configuration: ResponsesRuntimeURLProtocol.configuration()), store: false
        )
        let runtime = NativeAgentRuntime(
            configuration: .init(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil),
            makeClient: { _ in client }
        )
        var events: [String] = []
        runtime.onNotification = { method, _ in events.append(method) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Question"]]])
        await waitUntil { events.contains("turn/completed") || events.contains("error") }
        XCTAssertTrue(events.contains("error"))
        XCTAssertFalse(events.contains("turn/completed"))
    }

    func testResponsesIncompleteStreamCannotRecoverFromDoneItems() async throws {
        let responseURL = URL(string: "https://responses-runtime-test.invalid/v1/responses")!
        let responseBody = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

        data: {"type":"response.incomplete","response":{"id":"resp_test","status":"incomplete","output":[]}}

        """
        ResponsesRuntimeURLProtocol.install(url: responseURL, body: Data(responseBody.utf8))
        defer { ResponsesRuntimeURLProtocol.remove(url: responseURL) }
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "test",
            baseURL: URL(string: "https://responses-runtime-test.invalid/v1/")!,
            session: URLSession(configuration: ResponsesRuntimeURLProtocol.configuration()), store: false
        )
        let runtime = NativeAgentRuntime(
            configuration: .init(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil),
            makeClient: { _ in client }
        )
        var events: [String] = []
        runtime.onNotification = { method, _ in events.append(method) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Question"]]])
        await waitUntil { events.contains("turn/completed") || events.contains("error") }
        XCTAssertTrue(events.contains("error"))
        XCTAssertFalse(events.contains("turn/completed"))
    }

    func testFalseCloseMarkerStaysInvalidAndDoesNotInvokeToolHandler() async throws {
        let configuration = NativeAgentRuntime.Configuration(
            projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(),
            sessionID: UUID(), modelID: "test", effort: nil
        )
        var handlerCalls = 0
        let runtime = NativeAgentRuntime(
            configuration: configuration,
            makeClient: { _ in
                ScriptedClient(script: [
                    .toolCallStart(index: 0, id: "edit", name: "fs_edit_file", kind: .function),
                    .toolCallDelta(index: 0, arguments: "{\"relative_path\":\"a.txt\",\"old_text\":\"\",\"new_text\":\"x\"}"),
                    .finished(usage: nil),
                    .streamClosed(terminalMarkerSeen: false),
                    .streamClosed(terminalMarkerSeen: true)
                ], provider: .openAI)
            },
            dynamicToolHandler: { _ in handlerCalls += 1; return .accepted("unexpected") }
        )
        var events: [String] = []
        runtime.onNotification = { method, _ in events.append(method) }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Edit"]]])
        await waitUntil { events.contains("error") }
        XCTAssertEqual(handlerCalls, 0)
    }

    func testSteerRejectsAnotherThread() async throws {
        let configuration = NativeAgentRuntime.Configuration(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil)
        let runtime = NativeAgentRuntime(configuration: configuration) { _ in
            ScriptedClient(script: [.content("wait"), .finished(usage: nil)])
        }
        let first = try await runtime.request(method: "thread/start", params: [:])
        let firstID = try XCTUnwrap((first["thread"] as? [String: Any])?["id"] as? String)
        let second = try await runtime.request(method: "thread/start", params: [:])
        let secondID = try XCTUnwrap((second["thread"] as? [String: Any])?["id"] as? String)
        let turn = try await runtime.request(method: "turn/start", params: ["threadId": firstID, "input": [["type": "text", "text": "Question"]]])
        let turnID = try XCTUnwrap((turn["turn"] as? [String: Any])?["id"] as? String)
        do {
            _ = try await runtime.request(method: "turn/steer", params: ["threadId": secondID, "expectedTurnId": turnID, "input": [["type": "text", "text": "Wrong"]]])
            XCTFail("Cross-thread steer was accepted")
        } catch {}
    }

    func testReasoningDetailsArePreservedForTheNextProviderRequest() async throws {
        let client = RecordingClient(scripts: [
            [
                .reasoningDetails([.string("opaque")]),
                .toolCallStart(index: 0, id: "edit", name: "fs_edit_file", kind: .function),
                .toolCallDelta(index: 0, arguments: "{\"relative_path\":\"a.txt\",\"old_text\":\"\",\"new_text\":\"x\"}"),
                .finished(usage: nil)
            ],
            [.content("Done"), .finished(usage: nil)]
        ])
        let runtime = NativeAgentRuntime(
            configuration: .init(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil),
            makeClient: { _ in client },
            dynamicToolHandler: { _ in .accepted("edited") }
        )
        var complete = false
        runtime.onNotification = { method, _ in if method == "turn/completed" { complete = true } }
        let thread = try await runtime.request(method: "thread/start", params: [:])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Edit"]]])
        await waitUntil { complete }
        let requests = client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains { if case let .assistant(message) = $0 { return message.reasoningDetails == [.string("opaque")] }; return false })
    }

    func testAskModeRejectsHallucinatedEditWithoutHandler() async throws {
        var calls = 0
        let runtime = NativeAgentRuntime(configuration: .init(projectID: UUID(), projectRoot: URL(fileURLWithPath: "/tmp"), profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil), makeClient: { _ in
            ScriptedClient(script: [.toolCallStart(index: 0, id: "edit", name: "fs_edit_file", kind: .function), .toolCallDelta(index: 0, arguments: "{\"relative_path\":\"a.txt\",\"old_text\":\"\",\"new_text\":\"x\"}"), .finished(usage: nil), .content("done"), .finished(usage: nil)])
        }, dynamicToolHandler: { _ in calls += 1; return .accepted("bad") })
        var events: [String] = []
        runtime.onNotification = { method, _ in events.append(method) }
        let response = try await runtime.request(method: "thread/start", params: ["agentMode": "ask"])
        let id = try XCTUnwrap((response["thread"] as? [String: Any])?["id"] as? String)
        _ = try await runtime.request(method: "turn/start", params: ["threadId": id, "input": [["type":"text", "text":"edit"]]])
        await waitUntil { events.contains("error") }
        XCTAssertEqual(calls, 0)
    }

    func testAskAndPlanRejectInjectedDevelopmentCommandsEvenWhenProjectCapabilityIsEnabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("marker")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let capabilities = ProjectCapabilityStore(projectURL: root, applicationSupportURL: support)
        try await capabilities.setEnabled(.developmentCommands, enabled: true)
        for mode in [AgentMode.ask, .plan] {
            let runtime = NativeAgentRuntime(
                configuration: .init(projectID: UUID(), projectRoot: root, profileID: UUID(), sessionID: UUID(), modelID: "test", effort: nil, capabilityRoot: support),
                makeClient: { _ in
                    ScriptedClient(script: [
                        .toolCallStart(index: 0, id: "command", name: "run_development_command", kind: .function),
                        .toolCallDelta(index: 0, arguments: "{\"arguments\":[\"/usr/bin/touch\",\"marker\"]}"),
                        .finished(usage: nil), .content("done"), .finished(usage: nil)
                    ])
                }
            )
            var events: [String] = []
            runtime.onNotification = { method, _ in events.append(method) }
            let thread = try await runtime.request(method: "thread/start", params: ["agentMode": mode.rawValue])
            let id = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
            _ = try await runtime.request(method: "turn/start", params: ["threadId": id, "input": [["type": "text", "text": "run"]]])
            await waitUntil { events.contains("turn/completed") || events.contains("error") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPlanWriterRejectsSymlinkedPlanTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".fs/plans"), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".fs/plans/p.md"), withDestinationURL: target)
        let result = await NativeProjectTools(rootURL: root).execute(name: "fs_write_plan", arguments: ["relative_path":".fs/plans/p.md", "content":"---\nstatus: draft\napproved_via: none\n---\n"], mode: .plan)
        XCTAssertFalse(result.hasPrefix("Saved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testBuildPlanStatusUpdateRequiresSelectedApprovedPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ProjectPlanStore(projectURL: root)
        _ = try store.saveDraft(planID: "selected", title: "Selected", format: .short, body: "## Objective\nKeep\n\n## Steps\n- Status: pending", expectedRevision: nil)
        _ = try store.approve(planID: "selected")
        let plan = try store.read(planID: "selected")
        let update = plan.markdown.replacingOccurrences(of: "status: approved", with: "status: in_progress")
        let tools = NativeProjectTools(rootURL: root)
        let accepted = await tools.execute(name: "fs_update_plan", arguments: ["plan_id":"selected", "expected_revision":"\(plan.metadata.revision)", "markdown":update], mode: .build, selectedPlanID: "selected")
        XCTAssertTrue(accepted.hasPrefix("Updated"))
        let denied = await tools.execute(name: "fs_update_plan", arguments: ["plan_id":"selected", "expected_revision":"\(plan.metadata.revision)", "markdown":update], mode: .ask, selectedPlanID: "selected")
        XCTAssertFalse(denied.hasPrefix("Updated"))
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<500 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
    }
}

private struct ScriptedClient: LLMClient {
    let script: [StreamDelta]
    let provider: ProviderIdentifier
    init(script: [StreamDelta], provider: ProviderIdentifier = .openAIResponses) {
        self.script = script
        self.provider = provider
    }
    var contextWindowSize: Int? { 128_000 }
    var providerIdentifier: ProviderIdentifier { provider }

    func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?, requestContext: RequestContext?) async throws -> AssistantMessage {
        AssistantMessage(content: "")
    }

    func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            script.forEach { continuation.yield($0) }
            continuation.yield(.streamClosed(terminalMarkerSeen: true))
            continuation.finish()
        }
    }
}

private final class ResponsesRuntimeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var responses: [String: Data] = [:]
    }

    private static let state = State()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesRuntimeURLProtocol.self]
        return configuration
    }

    static func install(url: URL, body: Data) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.responses[url.absoluteString] = body
    }

    static func remove(url: URL) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.responses.removeValue(forKey: url.absoluteString)
    }

    override static func canInit(with request: URLRequest) -> Bool { request.url != nil }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.lock.lock()
        let body = Self.state.responses[url.absoluteString]
        Self.state.lock.unlock()
        guard let body,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


private final class RecordingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [[StreamDelta]]
    private(set) var requests: [[ChatMessage]] = []
    init(scripts: [[StreamDelta]]) { remaining = scripts }
    var contextWindowSize: Int? { 128_000 }
    var providerIdentifier: ProviderIdentifier { .openAIResponses }
    func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?, requestContext: RequestContext?) async throws -> AssistantMessage { AssistantMessage(content: "") }
    func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?) -> AsyncThrowingStream<StreamDelta, Error> {
        lock.lock(); requests.append(messages); let script = remaining.isEmpty ? [] : remaining.removeFirst(); lock.unlock()
        return AsyncThrowingStream { continuation in
            script.forEach { continuation.yield($0) }
            continuation.yield(.streamClosed(terminalMarkerSeen: true))
            continuation.finish()
        }
    }
}
