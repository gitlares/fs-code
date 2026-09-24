import Foundation
import XCTest
@testable import AgentConnectionCore

final class ChatGPTOAuthTests: XCTestCase {
    func testDeviceAuthorizationUsesCompatibilityClientAndBoundsInvalidInterval() async throws {
        let store = MemoryCredentialStore()
        let recorder = HTTPRecorder(responses: [
            .init(status: 200, json: ["device_auth_id": "device", "user_code": "ABCD", "interval": "0"])
        ])
        let client = ChatGPTOAuthClient(store: store, execute: recorder.execute)

        let authorization = try await client.startDeviceAuthorization()

        XCTAssertEqual(authorization.userCode, "ABCD")
        XCTAssertEqual(authorization.pollInterval, 1)
        let requests = await recorder.allRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/accounts/deviceauth/usercode")
        XCTAssertTrue(String(data: request.body ?? Data(), encoding: .utf8)?.contains(ChatGPTOAuthClient.compatibilityClientID) == true)
    }

    func testTypedRecordsAreIsolatedByProjectAndProfile() async throws {
        let store = MemoryCredentialStore()
        let projectA = ProjectCredentialScope(projectID: UUID(), profileID: UUID())
        let projectB = ProjectCredentialScope(projectID: UUID(), profileID: projectA.profileID)
        let otherProfile = ProjectCredentialScope(projectID: projectA.projectID!, profileID: UUID())

        let storedAPIKey = try await store.replace(.apiKey("api-secret"), for: projectA, ifGeneration: nil)
        let storedTokens = try await store.replace(.chatGPT(tokens()), for: projectB, ifGeneration: nil)
        XCTAssertTrue(storedAPIKey)
        XCTAssertTrue(storedTokens)

        let apiKey = try await store.credential(for: projectA)
        let chatGPT = try await store.credential(for: projectB)
        let missing = try await store.credential(for: otherProfile)
        XCTAssertEqual(apiKey, .apiKey("api-secret"))
        XCTAssertEqual(chatGPT, .chatGPT(tokens()))
        XCTAssertNil(missing)
    }

    func testConcurrentRefreshIsSingleFlightAndCannotResurrectReplacement() async throws {
        let store = MemoryCredentialStore()
        let scope = ProjectCredentialScope(projectID: UUID(), profileID: UUID())
        let stored = try await store.replace(.chatGPT(tokens(expiry: .distantPast)), for: scope, ifGeneration: nil)
        XCTAssertTrue(stored)
        let gate = SuspensionGate()
        let recorder = HTTPRecorder(responses: [
            .init(status: 200, json: ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600])
        ], gate: gate)
        let client = ChatGPTOAuthClient(store: store, execute: recorder.execute)

        async let first: String? = try? await client.accessToken(for: scope)
        async let second: String? = try? await client.accessToken(for: scope)
        await store.waitForSnapshots(2)
        await recorder.waitForRequest()
        try await store.removeCredential(for: scope)
        let replacement = tokens()
        let replaced = try await store.replace(.chatGPT(replacement), for: scope, ifGeneration: nil)
        XCTAssertTrue(replaced)
        await gate.open()
        let firstResult = await first
        let secondResult = await second
        let requestCount = await recorder.requestCount
        let credential = try await store.credential(for: scope)
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertEqual(credential, .chatGPT(replacement))
    }

    func testJWTMetadataDecodesPayloadWithoutTreatingItAsVerified() {
        let payload = Data(#"{"sub":"not-an-account","https://api.openai.com/auth":{"chatgpt_account_id":"acct-1"},"email":"person@example.com","name":"Person","exp":200}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let metadata = ChatGPTOAuthClient.accountMetadata(from: "header.\(payload).signature")
        XCTAssertEqual(metadata?.accountID, "acct-1")
        XCTAssertEqual(metadata?.email, "person@example.com")
        XCTAssertEqual(metadata?.displayName, "Person")
        XCTAssertEqual(metadata?.expiresAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(ChatGPTOAuthClient.accountMetadata(from: "not-a-jwt"))
        let subOnly = Data(#"{"sub":"must-not-route"}"#.utf8).base64EncodedString()
        XCTAssertNil(ChatGPTOAuthClient.accountMetadata(from: "header.\(subOnly).signature")?.accountID)
    }

    private func tokens(expiry: Date = .distantFuture) -> ChatGPTOAuthTokens {
        ChatGPTOAuthTokens(accessToken: "access", idToken: nil, refreshToken: "refresh", expiresAt: expiry)
    }
}

private actor MemoryCredentialStore: ProjectCredentialStore {
    private var values: [ProjectCredentialScope: ProjectCredential] = [:]
    private var versions: [ProjectCredentialScope: UInt64] = [:]
    private var snapshotCount = 0
    private var snapshotWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func credential(for scope: ProjectCredentialScope) -> ProjectCredential? { values[scope] }
    func snapshot(for scope: ProjectCredentialScope) -> ProjectCredentialSnapshot {
        snapshotCount += 1
        let ready = snapshotWaiters.filter { $0.0 <= snapshotCount }
        snapshotWaiters.removeAll { $0.0 <= snapshotCount }
        ready.forEach { $0.1.resume() }
        return ProjectCredentialSnapshot(credential: values[scope], generation: versions[scope, default: 0])
    }
    func generation(for scope: ProjectCredentialScope) -> UInt64 { versions[scope, default: 0] }
    func replace(_ credential: ProjectCredential, for scope: ProjectCredentialScope, ifGeneration expected: UInt64?) -> Bool {
        let current = versions[scope, default: 0]
        guard expected == nil || expected == current else { return false }
        values[scope] = credential
        versions[scope] = current &+ 1
        return true
    }
    func removeCredential(for scope: ProjectCredentialScope) {
        values.removeValue(forKey: scope)
        versions[scope, default: 0] &+= 1
    }
    func waitForSnapshots(_ count: Int) async {
        if snapshotCount >= count { return }
        await withCheckedContinuation { snapshotWaiters.append((count, $0)) }
    }
}

private actor HTTPRecorder {
    struct Response {
        let status: Int
        let json: [String: Any]
    }

    struct Request {
        let url: URL?
        let body: Data?
    }

    private var responses: [Response]
    private var requests: [Request] = []
    private let gate: SuspensionGate?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(responses: [Response], gate: SuspensionGate? = nil) {
        self.responses = responses
        self.gate = gate
    }

    nonisolated func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await self.respond(to: request)
    }

    func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(url: request.url, body: request.httpBody))
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        if let gate { await gate.wait() }
        let response = responses.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: response.json)
        return (data, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
    }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    var requestCount: Int { requests.count }
    var allRequests: [Request] { requests }
}

private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
