import Foundation
import XCTest
@testable import AgentConnectionCore

@MainActor
final class AgentConversationQueueTests: XCTestCase {
    func testQueuedMessagesDrainFIFOAfterEachCompletion() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()

        manager.updateDraft("first")
        await manager.send()
        manager.updateDraft("second")
        await manager.send()
        manager.updateDraft("third")
        await manager.send()
        XCTAssertEqual(manager.queuedMessages.map(\.text), ["second", "third"])

        transport.completeCurrentTurn()
        await waitUntil {
            transport.turnInputs.count == 2
                && manager.queuedMessages.map(\.text) == ["third"]
                && manager.messages.contains(where: { $0.text == "second" })
        }
        XCTAssertEqual(transport.turnInputs, ["first", "second"])
        XCTAssertEqual(manager.queuedMessages.map(\.text), ["third"])

        transport.completeCurrentTurn()
        await waitUntil {
            transport.turnInputs.count == 3
                && manager.queuedMessages.isEmpty
                && manager.messages.contains(where: { $0.text == "third" })
        }
        XCTAssertEqual(transport.turnInputs, ["first", "second", "third"])
        XCTAssertTrue(manager.queuedMessages.isEmpty)
    }

    func testAcceptedSteerAddsOnlyItsUserMessageAndDoesNotStartAnotherTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("steer this")
        await manager.send()
        let queuedID = try XCTUnwrap(manager.queuedMessages.first?.id)

        await manager.steerQueuedMessage(id: queuedID)

        XCTAssertEqual(transport.steerIDs, [queuedID.uuidString])
        XCTAssertEqual(transport.turnInputs, ["active"])
        XCTAssertEqual(manager.messages.filter { $0.text == "steer this" }.count, 1)
        XCTAssertTrue(manager.queuedMessages.isEmpty)
        XCTAssertFalse(manager.queueIsPaused)
    }

    func testCompletionBeforeSteerAcknowledgementDoesNotStartOrDuplicateQueuedTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("late steer")
        await manager.send()
        let queuedID = try XCTUnwrap(manager.queuedMessages.first?.id)
        transport.delaySteerResponse = true

        let steering = Task { @MainActor in await manager.steerQueuedMessage(id: queuedID) }
        await waitUntil { transport.steerIDs.count == 1 }
        transport.completeCurrentTurn()
        transport.resolveSteerResponse()
        await steering.value
        await waitUntil { manager.queuedMessages.isEmpty }

        XCTAssertEqual(transport.turnInputs, ["active"])
        XCTAssertEqual(manager.messages.filter { $0.text == "late steer" }.count, 1)
        XCTAssertTrue(manager.queuedMessages.isEmpty)
    }

    func testRejectedSteerRetainsQueuePausesAndKeepsActiveTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        transport.rejectSteer = true
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("retain this")
        await manager.send()
        let queuedID = try XCTUnwrap(manager.queuedMessages.first?.id)

        await manager.steerQueuedMessage(id: queuedID)

        XCTAssertTrue(manager.hasActiveTurn)
        XCTAssertTrue(manager.queueIsPaused)
        XCTAssertEqual(manager.queuedMessages.map(\.id), [queuedID])
    }

    func testLateSteerFailureAfterProfileSwitchDoesNotPauseNewConversation() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("old profile queued")
        await manager.send()
        let queuedID = try XCTUnwrap(manager.queuedMessages.first?.id)
        transport.delaySteerResponse = true
        let steering = Task { @MainActor in await manager.steerQueuedMessage(id: queuedID) }
        await waitUntil { transport.steerIDs.count == 1 }

        transport.switchProfile(to: UUID())
        _ = try await manager.newThread()
        transport.resolveSteerResponse()
        await steering.value
        await waitUntil { !manager.hasActiveTurn }

        XCTAssertFalse(manager.queueIsPaused)
        XCTAssertNil(manager.queueError)
        XCTAssertTrue(manager.queuedMessages.isEmpty)
    }

    func testConcurrentQueueSubmitsPersistOneCapturedDraft() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("queue once")

        let first = Task { @MainActor in await manager.send() }
        let second = Task { @MainActor in await manager.send() }
        await first.value
        await second.value

        XCTAssertEqual(manager.queuedMessages.map(\.text), ["queue once"])
    }

    func testStopPausesQueueAndCompletionDoesNotDrainIt() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("pending")
        await manager.send()

        await manager.stop()
        transport.completeCurrentTurn(status: "interrupted")
        await waitUntil { !manager.hasActiveTurn }

        XCTAssertTrue(manager.queueIsPaused)
        XCTAssertEqual(manager.queuedMessages.map(\.text), ["pending"])
        XCTAssertEqual(transport.turnInputs, ["active"])
    }

    func testQueueIsPausedWhenReloadedRatherThanAutomaticallySent() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let firstTransport = QueueTransport()
        let first = AgentConversationManager(projectURL: project, transport: firstTransport)
        try await first.load()
        _ = try await first.newThread()
        first.updateDraft("active")
        await first.send()
        first.updateDraft("pending after restart")
        await first.send()
        try await first.flush()

        let secondTransport = QueueTransport(profileID: firstTransport.selectedProfileID!)
        let reloaded = AgentConversationManager(projectURL: project, transport: secondTransport)
        try await reloaded.load()

        XCTAssertEqual(reloaded.queuedMessages.map(\.text), ["pending after restart"])
        XCTAssertTrue(reloaded.queueIsPaused)
        XCTAssertTrue(secondTransport.turnInputs.isEmpty)
    }

    func testFailedQueuedStartLeavesQueuePausedAndDoesNotLeaveAnActiveTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("will fail")
        await manager.send()
        transport.failNextTurnStart = true

        transport.completeCurrentTurn()
        await waitUntil {
            manager.queueIsPaused && transport.requests.filter { $0.method == "turn/start" }.count == 2
        }

        XCTAssertFalse(manager.hasActiveTurn)
        XCTAssertTrue(manager.queueIsPaused)
        XCTAssertEqual(manager.queuedMessages.map(\.text), ["will fail"])
    }

    func testRateLimitedResponsePausesQueueWithActionableReason() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = QueueTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("active")
        await manager.send()
        manager.updateDraft("pending")
        await manager.send()
        transport.failCurrentTurn(message: "The provider rate limit was reached. Wait a moment or switch to another connection.")

        await waitUntil { manager.queueIsPaused && !manager.hasActiveTurn }
        XCTAssertEqual(manager.queueError, "Queue paused because the provider rate limit was reached. Wait a moment or switch to another connection.")
        XCTAssertEqual(manager.queuedMessages.map(\.text), ["pending"])
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 where !predicate() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }
}

@MainActor
private final class QueueTransport: AgentConversationTransport {
    struct Request { let method: String; let params: [String: Any] }

    private(set) var selectedProfileID: UUID?
    var connectionState: AgentConnectionState = .connected(accountName: "Queue test")
    let connectionModels = [ConnectionModel(id: "test-model", displayName: "Test", isDefault: true, supportedReasoningEfforts: [], defaultReasoningEffort: nil)]
    let profileSelectedModelID: String? = "test-model"
    private var sessionID = UUID()
    private var threadID = "queue-thread"
    private var turnNumber = 0
    private var activeTurnID: String?
    var delaySteerResponse = false
    private var deferredSteer: CheckedContinuation<AgentConnectionRuntimeResponse, Error>?
    var failNextTurnStart = false
    var rejectSteer = false
    private var connectionObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var runtimeObservers: [UUID: @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void] = [:]
    private(set) var requests: [Request] = []
    private(set) var turnInputs: [String] = []
    private(set) var steerIDs: [String] = []

    init(profileID: UUID = UUID()) { selectedProfileID = profileID }
    func addConnectionObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID { let id = UUID(); connectionObservers[id] = observer; return id }
    func removeConnectionObserver(_ id: UUID) { connectionObservers[id] = nil }
    func addRuntimeObserver(_ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void) -> UUID { let id = UUID(); runtimeObservers[id] = observer; return id }
    func removeRuntimeObserver(_ id: UUID) { runtimeObservers[id] = nil }
    func setDynamicToolHandler(_ handler: @escaping @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult) -> UUID { UUID() }
    func removeDynamicToolHandler(_ token: UUID) {}
    func shutdown() async {}

    func request(method: String, params: [String: Any], expectedProfileID: UUID, expectedSessionID: UUID?) async throws -> AgentConnectionRuntimeResponse {
        requests.append(Request(method: method, params: params))
        switch method {
        case "thread/start", "thread/resume":
            return response(["thread": ["id": threadID], "instructionSources": [], "sandbox": ["type": "readOnly", "networkAccess": false]])
        case "turn/start":
            if failNextTurnStart { failNextTurnStart = false; throw AgentConnectionError.unavailable("start failed") }
            turnNumber += 1
            let turnID = "queue-turn-\(turnNumber)"
            activeTurnID = turnID
            let input = ((params["input"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            turnInputs.append(input)
            return response(["turn": ["id": turnID]])
        case "turn/steer":
            let clientID = params["clientUserMessageId"] as? String ?? ""
            steerIDs.append(clientID)
            if delaySteerResponse {
                return try await withCheckedThrowingContinuation { continuation in
                    deferredSteer = continuation
                }
            }
            return response(["turnId": rejectSteer ? "rejected-turn" : activeTurnID ?? ""])
        case "turn/interrupt":
            return response([:])
        default:
            throw AgentConnectionError.unavailable("Unexpected request \(method)")
        }
    }

    func completeCurrentTurn(status: String = "completed") {
        guard let profileID = selectedProfileID, let activeTurnID else { return }
        let event = AgentConnectionRuntimeEvent(
            profileID: profileID,
            sessionID: sessionID,
            method: "turn/completed",
            params: ["threadId": threadID, "turn": ["id": activeTurnID, "status": status, "items": []]]
        )
        for observer in runtimeObservers.values { observer(event) }
    }

    func failCurrentTurn(message: String) {
        guard let profileID = selectedProfileID, let activeTurnID else { return }
        let event = AgentConnectionRuntimeEvent(
            profileID: profileID,
            sessionID: sessionID,
            method: "error",
            params: ["threadId": threadID, "turnId": activeTurnID, "error": ["message": message]]
        )
        for observer in runtimeObservers.values { observer(event) }
    }

    func resolveSteerResponse() {
        let continuation = deferredSteer
        deferredSteer = nil
        continuation?.resume(returning: response(["turnId": activeTurnID ?? ""]))
    }

    func switchProfile(to profileID: UUID) {
        selectedProfileID = profileID
        sessionID = UUID()
        for observer in connectionObservers.values { observer() }
    }

    private func response(_ result: [String: Any]) -> AgentConnectionRuntimeResponse {
        AgentConnectionRuntimeResponse(profileID: selectedProfileID!, sessionID: sessionID, result: result)
    }
}
