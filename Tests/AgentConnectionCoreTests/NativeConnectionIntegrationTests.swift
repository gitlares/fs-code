import AgentRunKit
import Foundation
import XCTest
@testable import AgentConnectionCore

@MainActor
final class NativeConnectionIntegrationTests: XCTestCase {
    func testNativeConnectionRunsAuditedEditAndDoesNotShareCopiedProfileCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let vault = IntegrationVault()
        let oauth = ChatGPTOAuthClient(store: vault, execute: { _ in throw ChatGPTOAuthError.unavailable })
        let projectID = UUID()
        let connection = AgentConnectionManager(projectURL: root, projectID: projectID, supportURL: root.appendingPathComponent("support"), credentialStore: vault, oauth: oauth,
            catalogLoader: { _ in [.init(id: "test-model", displayName: "Test", isDefault: true)] },
            clientFactory: { _ in IntegrationClient() })
        let profile = try await connection.createProfile(name: "Project account", kind: .chatGPT, apiKey: nil)
        _ = await vault.replace(.chatGPT(.init(accessToken: "test", idToken: nil, refreshToken: "refresh", expiresAt: .distantFuture)), for: .init(projectID: projectID, profileID: profile.id), ifGeneration: nil)
        await connection.refreshSelected()
        XCTAssertEqual(connection.state, .connected(accountName: "Project account"))
        let conversation = AgentConversationManager(projectURL: root, connectionManager: connection)
        conversation.authorizeFileMutation = { _, _ in true }
        try await conversation.load()
        _ = try await conversation.newThread()
        conversation.updateDraft("Replace before with after in sample.txt")
        await conversation.send()
        for _ in 0..<200 {
            if conversation.messages.contains(where: { $0.role == .assistant && $0.text == "Edited sample.txt." }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after", "Activity: \(conversation.activity)")
        XCTAssertTrue(conversation.messages.contains { $0.text == "Edited sample.txt." })
        try await conversation.flush()
        try await conversation.shutdown()

        // Same connection metadata in another library project must not unlock the account.
        let other = AgentConnectionManager(projectURL: root, projectID: UUID(), supportURL: root.appendingPathComponent("support"), credentialStore: vault, oauth: oauth,
            catalogLoader: { _ in XCTFail("Must not fetch models without this project's credentials"); return [] },
            clientFactory: { _ in IntegrationClient() })
        try await other.load()
        await other.refreshSelected()
        if case .failed = other.state {} else { XCTFail("Copied profile should require reconnection") }
    }

    func testBrowserLoginReturnsToProjectWithoutDeviceAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = IntegrationVault()
        let oauth = ChatGPTOAuthClient(store: vault, execute: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            let body = (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "").removingPercentEncoding ?? ""
            XCTAssertTrue(body.contains("authorization_code"))
            XCTAssertTrue(body.contains("code_verifier="))
            XCTAssertTrue(body.contains("localhost"))
            let data = Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let connection = AgentConnectionManager(projectURL: root, projectID: UUID(), supportURL: root.appendingPathComponent("support"), credentialStore: vault, oauth: oauth,
            catalogLoader: { _ in [.init(id: "test-model", displayName: "Test", isDefault: true)] },
            clientFactory: { _ in IntegrationClient() })
        _ = try await connection.createProfile(name: "Browser account", kind: .chatGPT, apiKey: nil)
        let login = Task { await connection.connectSelected() }
        for _ in 0..<200 {
            if connection.pendingLoginURL != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let url = connection.pendingLoginURL else {
            await connection.cancelLogin()
            await login.value
            return XCTFail("Browser did not become ready: \(connection.state)")
        }
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertNil(connection.pendingDeviceCode)
        let state = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        var callback = URLComponents(string: "http://localhost:1455/auth/callback")!
        callback.queryItems = [.init(name: "code", value: "fake-code"), .init(name: "state", value: state)]
        _ = try await URLSession.shared.data(from: callback.url!)
        await login.value
        XCTAssertEqual(connection.state, .connected(accountName: "Browser account"))
        await connection.selectProfile(id: nil)
    }

    func testHistoryRestoresInterruptedToolWithoutReplayingAndIsolatesProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID(), profile = UUID()
        let store = NativeAgentHistoryStore(projectID: project, profileID: profile, rootOverride: root)
        XCTAssertNil(try store.load(threadID: "existing-ui-thread"))
        try store.save(threadID: "thread", messages: [.user("Edit"), .assistant(.init(content: "", toolCalls: [.init(id: "pending", name: "fs_edit_file", arguments: "{}")] ))])
        let restored = try XCTUnwrap(NativeAgentHistoryStore(projectID: project, profileID: profile, rootOverride: root).load(threadID: "thread"))
        XCTAssertEqual(restored.count, 3)
        guard case let .tool(id, _, content) = restored.last else { return XCTFail("Interrupted call needs a result, never replay") }
        XCTAssertEqual(id, "pending")
        XCTAssertTrue(content.contains("not replayed"))
        XCTAssertNil(try NativeAgentHistoryStore(projectID: project, profileID: UUID(), rootOverride: root).load(threadID: "thread"))
    }

    func testCatalogUsesBackendCapabilitiesAndFiltersUnsupportedEntries() throws {
        let data = Data(#"{"models":[{"slug":"test","display_name":"Test","visibility":"list","context_window":100000,"supported_reasoning_levels":[{"effort":"medium"},{"effort":"ultra"}],"default_reasoning_level":"medium"},{"slug":"hidden","visibility":"hide"}]}"#.utf8)
        let catalog = try NativeProviderConnection.parseCatalog(data, kind: .chatGPT)
        XCTAssertEqual(catalog.models.map(\.id), ["test"])
        XCTAssertEqual(catalog.models[0].supportedReasoningEfforts, ["medium"])
        XCTAssertEqual(catalog.windows["test"], 100000)
    }

    func testChatGPTCatalogUsesCodexProtocolCompatibilityVersion() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://chatgpt.com/backend-api/codex/"))
        let url = NativeProviderConnection.modelCatalogURL(baseURL: baseURL, kind: .chatGPT)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.path, "/backend-api/codex/models")
        XCTAssertEqual(components.queryItems, [.init(name: "client_version", value: "0.153.4")])
    }

    func testAPICatalogDoesNotUseChatGPTCompatibilityVersion() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/"))
        let url = NativeProviderConnection.modelCatalogURL(baseURL: baseURL, kind: .openAIAPI)

        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/models")
    }
}

private actor IntegrationVault: ProjectCredentialStore {
    var records: [ProjectCredentialScope: ProjectCredential] = [:]
    var versions: [ProjectCredentialScope: UInt64] = [:]
    func credential(for scope: ProjectCredentialScope) -> ProjectCredential? { records[scope] }
    func snapshot(for scope: ProjectCredentialScope) -> ProjectCredentialSnapshot {
        .init(credential: records[scope], generation: versions[scope, default: 0])
    }
    func generation(for scope: ProjectCredentialScope) -> UInt64 { versions[scope, default: 0] }
    func replace(_ credential: ProjectCredential, for scope: ProjectCredentialScope, ifGeneration expected: UInt64?) -> Bool {
        guard expected == nil || expected == versions[scope, default: 0] else { return false }
        records[scope] = credential; versions[scope, default: 0] += 1
        return true
    }
    func removeCredential(for scope: ProjectCredentialScope) { records[scope] = nil; versions[scope, default: 0] += 1 }
}

private struct IntegrationClient: LLMClient {
    var providerIdentifier: ProviderIdentifier { .openAIResponses }
    var contextWindowSize: Int? { 100000 }
    func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?, requestContext: RequestContext?) async throws -> AssistantMessage { .init(content: "") }
    func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?) -> AsyncThrowingStream<StreamDelta, Error> {
        let didEdit = messages.contains { if case .tool = $0 { return true }; return false }
        return AsyncThrowingStream { stream in
            if didEdit { stream.yield(.content("Edited sample.txt.")) }
            else {
                stream.yield(.toolCallStart(index: 0, id: "edit-one", name: "fs_edit_file", kind: .function))
                stream.yield(.toolCallDelta(index: 0, arguments: #"{"relative_path":"sample.txt","old_text":"before","new_text":"after"}"#))
            }
            stream.yield(.finished(usage: nil))
            stream.yield(.streamClosed(terminalMarkerSeen: true))
            stream.finish()
        }
    }
}
