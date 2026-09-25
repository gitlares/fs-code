import Foundation
import XCTest
@testable import AgentConnectionCore

@MainActor
final class AgentConversationTests: XCTestCase {
    func testExecuteApprovedPlanStartsBuildWithSelectedPlanMetadata() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let planStore = try ProjectPlanStore(projectURL: project)
        _ = try planStore.saveDraft(planID: "run-plan", title: "Run", format: .short, body: "## Objective\nRun\n\n## Steps\n- Status: pending", expectedRevision: nil)
        _ = try planStore.approve(planID: "run-plan")
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        try await manager.executePlan(planID: "run-plan")
        let request = try XCTUnwrap(transport.requests.first { $0.method == "thread/start" })
        XCTAssertEqual(request.params["agentMode"] as? String, "build")
        XCTAssertEqual(request.params["selectedPlanID"] as? String, "run-plan")
        XCTAssertTrue(manager.messages.contains { $0.role == .user && $0.text.contains("run-plan") })
    }

    func testExecuteUnapprovedPlanDoesNotStartTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let planStore = try ProjectPlanStore(projectURL: project)
        _ = try planStore.saveDraft(planID: "draft-plan", title: "Draft", format: .short, body: "## Objective\nDraft\n\n## Steps\n- Status: pending", expectedRevision: nil)
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        do {
            try await manager.executePlan(planID: "draft-plan")
            XCTFail("Unapproved plan started")
        } catch {}
        XCTAssertFalse(transport.requests.contains { $0.method == "turn/start" })
    }
    func testNewChatTitleExcludesRuntimeAttachmentEnvelope() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        let thread = try await manager.newThread()
        manager.updateDraft("What do you think of this file?\n\n<fs_code_attachments>\n{\"attachments\":[{\"sourcePath\":\"test.txt\"}]}\n</fs_code_attachments>")
        await manager.send()
        XCTAssertEqual(manager.threads.first(where: { $0.id == thread.id })?.title, "What do you think of this file?")
    }

    func testReasoningSummaryIsTransientBoundedAndIgnoresRawOrLateEvents() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Explain")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)
        let userID = try XCTUnwrap(manager.messages.first?.id)

        transport.emit(method: "item/reasoning/summaryPartAdded", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 0])
        XCTAssertNil(manager.liveProgressText)
        XCTAssertNil(manager.liveProgressUserMessageID)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 0, "delta": "Planning"])
        XCTAssertEqual(manager.liveProgressText, "Planning")
        XCTAssertEqual(manager.liveProgressUserMessageID, userID)
        transport.emit(method: "item/reasoning/summaryPartAdded", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 1])
        transport.emit(method: "item/reasoning/summaryTextDelta", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 1, "delta": "Checking"])
        XCTAssertEqual(manager.liveProgressText, "Checking")
        transport.emit(method: "item/reasoning/textDelta", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "delta": "raw"])
        XCTAssertEqual(manager.liveProgressText, "Checking")
        transport.emit(method: "item/reasoning/summaryPartAdded", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 2])
        transport.emit(method: "item/reasoning/summaryTextDelta", params: ["threadId": threadID, "turnId": turnID, "itemId": "reasoning", "summaryIndex": 2, "delta": String(repeating: "x", count: 5_000)])
        XCTAssertEqual(manager.liveProgressText?.utf8.count, 4_096)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: ["threadId": threadID, "turnId": "late", "itemId": "reasoning", "summaryIndex": 3, "delta": "ignored"])
        XCTAssertEqual(manager.liveProgressText?.utf8.count, 4_096)
        transport.switchProfile(to: UUID())
        XCTAssertNil(manager.liveProgressText)
        XCTAssertNil(manager.liveProgressUserMessageID)
        // A completion from the detached session must not recreate the prior turn's state.
        transport.emit(method: "turn/completed", params: ["threadId": threadID, "turn": ["id": turnID, "status": "completed", "items": []]])
        XCTAssertNil(manager.liveProgressText)
        XCTAssertNil(manager.liveProgressUserMessageID)
    }

    func testReasoningSummaryInterleavesCommentaryAndFinalPhaseWithoutResurrection() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Explain")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)

        let longSummary = String(repeating: "x", count: 5_000)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "reasoning-1",
            "summaryIndex": 0, "delta": longSummary
        ])
        XCTAssertEqual(manager.liveProgressText?.utf8.count, 4_096)

        transport.emit(method: "item/started", params: [
            "threadId": threadID, "turnId": turnID,
            "item": ["id": "commentary", "type": "agentMessage", "phase": "commentary"]
        ])
        transport.emit(method: "item/agentMessage/delta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "commentary", "delta": "Working note"
        ])
        XCTAssertEqual(manager.messages.last?.phase, .commentary)
        XCTAssertNil(manager.liveProgressText)

        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "reasoning-2",
            "summaryIndex": 0, "delta": "Rechecking"
        ])
        XCTAssertEqual(manager.liveProgressText, "Rechecking")
        var observerCount = 0
        let observerID = manager.addObserver { observerCount += 1 }
        defer { manager.removeObserver(observerID) }
        transport.emit(method: "item/started", params: [
            "threadId": threadID, "turnId": turnID,
            "item": ["id": "final", "type": "agentMessage", "phase": "final_answer"]
        ])
        XCTAssertGreaterThan(observerCount, 0)
        XCTAssertNil(manager.liveProgressText)
        transport.emit(method: "item/completed", params: [
            "threadId": threadID, "turnId": turnID,
            "item": ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": "Done"]
        ])
        XCTAssertEqual(manager.messages.last?.phase, .finalAnswer)
        XCTAssertNil(manager.liveProgressText)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "reasoning-3",
            "summaryIndex": 0, "delta": "late"
        ])
        XCTAssertNil(manager.liveProgressText)

    }

    func testStopClearsLiveReasoningAndRejectsLateSummary() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Explain")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "reasoning",
            "summaryIndex": 0, "delta": "Planning"
        ])
        XCTAssertEqual(manager.liveProgressText, "Planning")
        await manager.stop()
        XCTAssertNil(manager.liveProgressText)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "reasoning",
            "summaryIndex": 1, "delta": "late"
        ])
        XCTAssertNil(manager.liveProgressText)
    }

    func testConversationMessagePhaseDecodesLegacyAndExplicitValues() throws {
        let id = UUID()
        let legacy = "{\"id\":\"\(id.uuidString)\",\"role\":\"assistant\",\"text\":\"Saved\",\"createdAt\":0}".data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ConversationMessage.self, from: legacy).phase)
        let explicit = "{\"id\":\"\(id.uuidString)\",\"role\":\"assistant\",\"text\":\"Saved\",\"createdAt\":0,\"phase\":\"final_answer\"}".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ConversationMessage.self, from: explicit).phase, .finalAnswer)
        let future = "{\"id\":\"\(id.uuidString)\",\"role\":\"assistant\",\"text\":\"Saved\",\"createdAt\":0,\"phase\":\"future_phase\"}".data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ConversationMessage.self, from: future).phase)
    }

    func testEnsureInitialThreadWaitsForConnectionAndDoesNotDuplicateRepeatedCalls() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        transport.connectionState = .disconnected
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()

        let disconnected = try await manager.ensureInitialThread()
        XCTAssertNil(disconnected)
        XCTAssertTrue(manager.threads.isEmpty)

        transport.connectionState = .connected(accountName: "Test")
        transport.notifyConnectionObservers()
        let firstAttempt = Task { @MainActor in try await manager.ensureInitialThread() }
        let overlappingAttempt = Task { @MainActor in try await manager.ensureInitialThread() }
        let first = try await firstAttempt.value
        let overlapping = try await overlappingAttempt.value
        let repeated = try await manager.ensureInitialThread()

        XCTAssertTrue([first, overlapping].compactMap { $0?.id }.allSatisfy { $0 == repeated?.id })
        XCTAssertEqual(manager.selectedThreadID, repeated?.id)
        XCTAssertEqual(manager.threads.count, 1)
        XCTAssertEqual(manager.activity, .idle)
    }

    func testEnsureInitialThreadPreservesExistingSelectionAndHistory() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        transport.automaticReply = "Kept reply"
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        let first = try await manager.newThread()
        manager.updateDraft("Kept question")
        await manager.send()
        _ = try await manager.newThread()
        await manager.selectThread(id: first.id)
        let messagesBefore = manager.messages
        let threadCountBefore = manager.threads.count

        let ensured = try await manager.ensureInitialThread()

        XCTAssertEqual(ensured?.id, first.id)
        XCTAssertEqual(manager.selectedThreadID, first.id)
        XCTAssertEqual(manager.messages, messagesBefore)
        XCTAssertEqual(manager.threads.count, threadCountBefore)
    }

    func testBuffersStreamingUntilTurnIdentityIsConfirmedAndUsesReadOnlyProtocolShapes() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        transport.automaticReply = "A streamed answer"
        let manager = AgentConversationManager(projectURL: project, transport: transport)

        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Explain this project")
        await manager.send()

        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages.last?.text, "A streamed answer")
        XCTAssertEqual(manager.activity, .idle)

        let threadRequest = try XCTUnwrap(transport.requests.first { $0.method == "thread/start" })
        XCTAssertEqual(threadRequest.params["cwd"] as? String, project.path)
        XCTAssertEqual(threadRequest.params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(threadRequest.params["sandbox"] as? String, "read-only")
        let config = try XCTUnwrap(threadRequest.params["config"] as? [String: Any])
        XCTAssertEqual(config["project_doc_max_bytes"] as? Int, 0)
        let projects = try XCTUnwrap(config["projects"] as? [String: Any])
        let projectConfig = try XCTUnwrap(projects[project.path] as? [String: Any])
        XCTAssertEqual(projectConfig["trust_level"] as? String, "untrusted")
        let dynamicTools = try XCTUnwrap(threadRequest.params["dynamicTools"] as? [[String: Any]])
        XCTAssertEqual(dynamicTools.count, 1)
        XCTAssertEqual(dynamicTools.first?["type"] as? String, "function")
        XCTAssertEqual(dynamicTools.first?["name"] as? String, "fs_edit_file")
        let hostPolicy = try XCTUnwrap(threadRequest.params["developerInstructions"] as? String)
        XCTAssertEqual(
            hostPolicy,
            AgentPromptStore.defaults.prompt(for: .build)
                + "\n\nPROJECT CONTEXT\nProject root: \(project.path)\nProject instructions are supplied separately by the host."
        )

        let turnRequest = try XCTUnwrap(transport.requests.first { $0.method == "turn/start" })
        XCTAssertEqual(turnRequest.params["approvalPolicy"] as? String, "never")
        let sandbox = try XCTUnwrap(turnRequest.params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandbox["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
    }

    func testConversationsKeepIndependentThreadsAndHistories() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()

        transport.automaticReply = "First reply"
        let first = try await manager.newThread()
        manager.updateDraft("First question")
        await manager.send()

        transport.automaticReply = "Second reply"
        let second = try await manager.newThread()
        manager.updateDraft("Second question")
        await manager.send()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(transport.startedThreadIDs).count, 2)
        await manager.selectThread(id: first.id)
        XCTAssertEqual(manager.messages.map(\.text), ["First question", "First reply"])
        await manager.selectThread(id: second.id)
        XCTAssertEqual(manager.messages.map(\.text), ["Second question", "Second reply"])
    }

    func testStopPreservesPartialHistoryAndStaleAccountEventsAreDiscarded() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let firstProfileID = transport.selectedProfileID!
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Long request")
        await manager.send()

        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(
            method: "item/agentMessage/delta",
            params: ["threadId": threadID, "turnId": turnID, "itemId": "item-1", "delta": "Partial"]
        )
        await manager.stop()

        let interrupt = try XCTUnwrap(transport.requests.last { $0.method == "turn/interrupt" })
        XCTAssertEqual(interrupt.params["threadId"] as? String, threadID)
        XCTAssertEqual(interrupt.params["turnId"] as? String, turnID)
        transport.emit(
            method: "turn/completed",
            params: [
                "threadId": threadID,
                "turn": ["id": turnID, "status": "interrupted", "items": []]
            ]
        )
        XCTAssertEqual(manager.messages.last?.text, "Partial")
        XCTAssertEqual(manager.activity, .idle)

        transport.switchProfile(to: UUID())
        transport.emit(
            profileID: firstProfileID,
            method: "item/agentMessage/delta",
            params: ["threadId": threadID, "turnId": turnID, "itemId": "item-1", "delta": " stale"]
        )
        XCTAssertTrue(manager.messages.isEmpty)
        transport.switchProfile(to: firstProfileID)
        XCTAssertEqual(manager.messages.last?.text, "Partial")
    }

    func testHistoryPersistsWithoutCredentialsAndResumeUsesOwnedRemoteThread() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let profileID = UUID()
        let secret = "sk-test-must-not-be-persisted"
        let firstTransport = FakeConversationTransport(profileID: profileID, credentialSentinel: secret)
        firstTransport.automaticReply = "Persisted reply"
        var manager: AgentConversationManager? = AgentConversationManager(
            projectURL: project,
            transport: firstTransport
        )
        try await manager!.load()
        _ = try await manager!.newThread()
        manager!.updateDraft("Persist this")
        await manager!.send()
        try await manager!.flush()

        let storageURL = project.appendingPathComponent(".fscode/conversations.json")
        let bytes = try Data(contentsOf: storageURL)
        let persisted = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(persisted.contains(secret))
        XCTAssertTrue(persisted.contains(profileID.uuidString))
        XCTAssertTrue(persisted.contains("thread-1"))
        try await manager!.shutdown()
        manager = nil

        let secondTransport = FakeConversationTransport(profileID: profileID, credentialSentinel: secret)
        secondTransport.automaticReply = "Resumed reply"
        let reloaded = AgentConversationManager(projectURL: project, transport: secondTransport)
        try await reloaded.load()
        XCTAssertEqual(reloaded.messages.map(\.text), ["Persist this", "Persisted reply"])
        reloaded.updateDraft("Continue")
        await reloaded.send()

        let resume = try XCTUnwrap(secondTransport.requests.first { $0.method == "thread/resume" })
        XCTAssertEqual(resume.params["threadId"] as? String, "thread-1")
        XCTAssertEqual(resume.params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(reloaded.messages.last?.text, "Resumed reply")
    }

    func testUnexpectedInstructionSourceAndCorruptExternalFileAreNeverOverwritten() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        transport.instructionSources = [project.appendingPathComponent("AGENTS.md").path]
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Do not send this")
        await manager.send()
        guard case .failed(let message) = manager.activity else {
            return XCTFail("Unexpected instruction sources must fail closed")
        }
        XCTAssertTrue(message.contains("instructions"))
        XCTAssertFalse(transport.requests.contains(where: { $0.method == "turn/start" }))

        let storageURL = project.appendingPathComponent(".fscode/conversations.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: storageURL)
        manager.updateDraft("preserved in memory")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try Data(contentsOf: storageURL), corrupt)
        XCTAssertEqual(manager.draft, "preserved in memory")
    }

    func testOversizedDraftIsPreservedInMemoryAndCannotBeSentOrSilentlySaved() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        let oversized = String(repeating: "x", count: 512 * 1_024 + 1)

        manager.updateDraft(oversized)

        XCTAssertEqual(manager.draft, oversized)
        XCTAssertFalse(manager.canSend)
        guard case .failed(let message) = manager.activity else {
            return XCTFail("Oversized input must expose a visible failure")
        }
        XCTAssertTrue(message.contains("too large"))
        await manager.send()
        XCTAssertFalse(transport.requests.contains(where: { $0.method == "thread/start" }))
    }

    func testMissingTurnIdentifierFailsExplicitlyInsteadOfRemainingStarting() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        transport.invalidTurnResponse = true
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Start")

        await manager.send()

        XCTAssertFalse(manager.hasActiveTurn)
        guard case .failed(let message) = manager.activity else {
            return XCTFail("A missing turn ID must fail explicitly")
        }
        XCTAssertTrue(message.contains("turn identifier"))
    }

    func testFileEditToolFailsClosedForDirtyBufferWithoutWriting() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let fileURL = project.appendingPathComponent("Notes.txt")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        manager.authorizeFileMutation = { _, _ in false }
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Change Notes.txt")
        await manager.send()

        let result = try await transport.invokeFileEdit(
            relativePath: "Notes.txt",
            oldText: "before",
            newText: "after"
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("unsaved edits"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "before")
        XCTAssertTrue(manager.fileChangeProposals.isEmpty)
        XCTAssertTrue(manager.appliedChanges.isEmpty)
    }

    func testFileEditAutoAppliesWithTurnMetadataAndCanRevertHunk() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let fileURL = project.appendingPathComponent("Notes.txt")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        let mutationRecorder = MutationResultRecorder()
        manager.authorizeFileMutation = { _, _ in true }
        manager.didCompleteFileMutation = { mutationRecorder.results.append($0) }
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Change Notes.txt")
        await manager.send()

        let result = try await transport.invokeFileEdit(
            relativePath: "Notes.txt",
            oldText: "before",
            newText: "after"
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after")
        let record = try XCTUnwrap(manager.appliedChanges.first)
        XCTAssertEqual(record.relativePath, "Notes.txt")
        XCTAssertEqual(record.status, .applied)
        XCTAssertEqual(manager.agentModifiedPaths, Set(["Notes.txt"]))
        XCTAssertEqual(manager.turnFileChanges.count, 1)
        XCTAssertEqual(manager.turnFileChanges.first?.threadID, transport.lastThreadID)
        XCTAssertEqual(manager.turnFileChanges.first?.turnID, transport.lastTurnID)
        XCTAssertEqual(manager.messages.first?.turnID, transport.lastTurnID)
        let hunk = try XCTUnwrap(record.changeHunks.first)
        XCTAssertEqual(hunk.relativePath, "Notes.txt")
        XCTAssertEqual(mutationRecorder.results.last?.relativePath, "Notes.txt")
        XCTAssertEqual(mutationRecorder.results.last?.operation, .apply)
        XCTAssertTrue(manager.fileChangeProposals.isEmpty)

        try await manager.revertChangeHunk(recordID: record.id, hunkID: hunk.id)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "before")
        XCTAssertEqual(manager.appliedChanges.first?.status, .reverted)
        XCTAssertTrue(manager.agentModifiedPaths.isEmpty)
        XCTAssertEqual(mutationRecorder.results.last?.hunkID, hunk.id)
    }

    func testRestorePointChecksEveryDirtyBufferBeforeWriting() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let alpha = project.appendingPathComponent("Alpha.txt")
        let beta = project.appendingPathComponent("Beta.txt")
        try "before".write(to: alpha, atomically: true, encoding: .utf8)
        try "before".write(to: beta, atomically: true, encoding: .utf8)
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        manager.authorizeFileMutation = { _, _ in true }
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Change files")
        await manager.send()
        let turnID = try XCTUnwrap(transport.lastTurnID)
        let alphaResult = try await transport.invokeFileEdit(
            relativePath: "Alpha.txt", oldText: "before", newText: "after"
        )
        let betaResult = try await transport.invokeFileEdit(
            relativePath: "Beta.txt", oldText: "before", newText: "after"
        )
        XCTAssertTrue(alphaResult.success)
        XCTAssertTrue(betaResult.success)
        transport.emit(method: "turn/completed", params: [
            "threadId": try XCTUnwrap(transport.lastThreadID),
            "turn": ["id": turnID, "status": "completed", "items": []]
        ])
        manager.authorizeFileMutation = { path, _ in path != "Beta.txt" }

        do {
            try await manager.restorePoint(turnID: turnID)
            XCTFail("Expected restore to be blocked by the dirty Beta buffer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing was written"))
        }
        XCTAssertEqual(try String(contentsOf: alpha, encoding: .utf8), "after")
        XCTAssertEqual(try String(contentsOf: beta, encoding: .utf8), "after")
    }

    func testFileEditCannotApplyAfterAccountSwitchDuringDirtyBufferCheck() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let fileURL = project.appendingPathComponent("Notes.txt")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        manager.authorizeFileMutation = { _, _ in
            transport.switchProfile(to: UUID())
            return true
        }
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Change Notes.txt")
        await manager.send()

        let result = try await transport.invokeFileEdit(
            relativePath: "Notes.txt",
            oldText: "before",
            newText: "after"
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "before")
        XCTAssertTrue(manager.fileChangeProposals.isEmpty)
    }

    func testInputContextUsageAcceptsZeroAndLateUsageButRejectsMalformedOrStaleEvents() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Count tokens")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)

        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 0], "modelContextWindow": 128_000]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 0)
        XCTAssertEqual(manager.lastRequestInputContext?.modelContextWindow, 128_000)
        XCTAssertNil(manager.lastRequestInputContext?.cacheReadTokens)
        XCTAssertNil(manager.lastRequestInputContext?.cacheWriteTokens)

        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 1, "cacheReadTokens": 0, "cacheWriteTokens": 0], "modelContextWindow": 128_000]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.cacheReadTokens, 0)
        XCTAssertEqual(manager.lastRequestInputContext?.cacheWriteTokens, 0)

        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 2, "cacheReadTokens": 1]]
        ])
        XCTAssertNil(manager.lastRequestInputContext?.modelContextWindow)
        XCTAssertEqual(manager.lastRequestInputContext?.cacheReadTokens, 1)

        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": true], "modelContextWindow": 1]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 2)
        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": -1], "modelContextWindow": 128_000]
        ])
        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 1], "modelContextWindow": 0]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 2)

        transport.emit(method: "turn/completed", params: [
            "threadId": threadID,
            "turn": ["id": turnID, "status": "completed", "items": []]
        ])
        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 42], "modelContextWindow": 128_000]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 42)

        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": "other-turn",
            "tokenUsage": ["last": ["inputTokens": 99], "modelContextWindow": 128_000]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 42)
    }

    func testInputContextUsageParsesJSONSerializationNumbersWithoutAcceptingBoolsOrFractions() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Count serialized tokens")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)

        func emitSerialized(inputTokens: Any, window: Any) throws {
            let object: [String: Any] = [
                "threadId": threadID,
                "turnId": turnID,
                "tokenUsage": ["last": ["inputTokens": inputTokens], "modelContextWindow": window]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let params = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            transport.emit(method: "thread/tokenUsage/updated", params: params)
        }

        try emitSerialized(inputTokens: 0, window: 128_000)
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 0)
        try emitSerialized(inputTokens: 1, window: 128_000)
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 1)
        try emitSerialized(inputTokens: true, window: 128_000)
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 1)
        try emitSerialized(inputTokens: 1.5, window: 128_000)
        XCTAssertEqual(manager.lastRequestInputContext?.inputTokens, 1)
    }

    func testActivitySummariesArePerTurnAndDoNotEnterMessages() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Inspect files")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let firstTurnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(method: "item/started", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "reasoning-1", "type": "reasoning", "text": "private reasoning"]
        ])
        transport.emit(method: "item/completed", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "reasoning-1", "type": "reasoning", "status": "completed", "text": "private reasoning"]
        ])
        transport.emit(method: "item/started", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "command-1", "type": "commandExecution", "command": "rg TODO"]
        ])
        transport.emit(method: "item/completed", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "command-1", "type": "commandExecution", "command": "rg TODO", "status": "completed", "output": String(repeating: "x", count: 20_000)]
        ])
        transport.emit(method: "item/started", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "tool-1", "type": "dynamicToolCall", "tool": "fs_edit_file"]
        ])
        transport.emit(method: "item/completed", params: [
            "threadId": threadID,
            "turnId": firstTurnID,
            "item": ["id": "tool-1", "type": "dynamicToolCall", "tool": "fs_edit_file", "status": "completed", "contentItems": [["type": "inputText", "text": "Applied Notes.txt"]]]
        ])
        transport.emit(method: "turn/completed", params: [
            "threadId": threadID,
            "turn": ["id": firstTurnID, "status": "completed", "items": []]
        ])

        let firstSummary = try XCTUnwrap(manager.turnActivitySummaries.first)
        XCTAssertEqual(firstSummary.remoteTurnID, firstTurnID)
        XCTAssertEqual(firstSummary.activities.count, 3)
        XCTAssertNil(firstSummary.activities.first(where: { $0.itemID == "reasoning-1" })?.output)
        XCTAssertEqual(firstSummary.activities.first(where: { $0.itemID == "command-1" })?.output?.utf8.count, 16_384)
        XCTAssertEqual(firstSummary.activities.first(where: { $0.itemID == "tool-1" })?.operation, "fs_edit_file")
        XCTAssertEqual(firstSummary.activities.first(where: { $0.itemID == "tool-1" })?.output, "Applied Notes.txt")
        XCTAssertEqual(manager.messages.map(\.role), [.user])

        manager.updateDraft("Second request")
        await manager.send()
        let secondTurnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(method: "turn/completed", params: [
            "threadId": threadID,
            "turn": ["id": secondTurnID, "status": "completed", "items": []]
        ])
        XCTAssertEqual(manager.turnActivitySummaries.count, 2)
        XCTAssertNotEqual(manager.turnActivitySummaries[0].userMessageID, manager.turnActivitySummaries[1].userMessageID)
    }

    func testCommentaryAndFinalAgentItemsRemainSeparateMessages() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("Explain")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(method: "item/agentMessage/delta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "commentary", "delta": "Looking…"
        ])
        transport.emit(method: "item/agentMessage/delta", params: [
            "threadId": threadID, "turnId": turnID, "itemId": "final", "delta": "Answer"
        ])
        transport.emit(method: "turn/completed", params: [
            "threadId": threadID,
            "turn": ["id": turnID, "status": "completed", "items": [
                ["id": "commentary", "type": "agentMessage", "text": "Looking…"],
                ["id": "final", "type": "agentMessage", "text": "Answer complete"]
            ]]
        ])
        XCTAssertEqual(manager.messages.map(\.text), ["Explain", "Looking…", "Answer complete"])
    }

    func testModelChangeRejectsLateUsageFromThePreviousTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let transport = FakeConversationTransport()
        let manager = AgentConversationManager(projectURL: project, transport: transport)
        try await manager.load()
        _ = try await manager.newThread()
        manager.updateDraft("First request")
        await manager.send()
        let threadID = try XCTUnwrap(transport.lastThreadID)
        let turnID = try XCTUnwrap(transport.lastTurnID)
        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 13, "cacheReadTokens": 7], "modelContextWindow": 128_000]
        ])
        XCTAssertEqual(manager.lastRequestInputContext?.cacheReadTokens, 7)
        transport.emit(method: "turn/completed", params: [
            "threadId": threadID,
            "turn": ["id": turnID, "status": "completed", "items": []]
        ])

        try await manager.selectModel(id: nil)
        transport.emit(method: "thread/tokenUsage/updated", params: [
            "threadId": threadID,
            "turnId": turnID,
            "tokenUsage": ["last": ["inputTokens": 13], "modelContextWindow": 128_000]
        ])
        XCTAssertNil(manager.lastRequestInputContext)
    }

    func testLegacyConversationDocumentWithoutTelemetryLoads() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let profileID = UUID()
        let conversationID = UUID()
        let legacy: [String: Any] = [
            "version": 1,
            "projectPath": project.path,
            "selectedThreadIDs": [profileID.uuidString: conversationID.uuidString],
            "conversations": [[
                "id": conversationID.uuidString,
                "profileID": profileID.uuidString,
                "title": "Legacy Chat",
                "createdAt": Date().timeIntervalSinceReferenceDate,
                "updatedAt": Date().timeIntervalSinceReferenceDate,
                "draft": "",
                "messages": []
            ]]
        ]
        let directory = project.appendingPathComponent(".fscode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: legacy, options: [])
        try data.write(to: directory.appendingPathComponent("conversations.json"))

        let manager = AgentConversationManager(
            projectURL: project,
            transport: FakeConversationTransport(profileID: profileID)
        )
        try await manager.load()
        XCTAssertEqual(manager.threads.map(\.title), ["Legacy Chat"])
        XCTAssertNil(manager.lastRequestInputContext)
        XCTAssertTrue(manager.turnActivitySummaries.isEmpty)
    }

    private func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSCodeConversationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
private final class MutationResultRecorder {
    var results: [ConversationFileMutationResult] = []
}

@MainActor
private final class FakeConversationTransport: AgentConversationTransport {
    struct Request {
        let method: String
        let params: [String: Any]
        let expectedProfileID: UUID
        let expectedSessionID: UUID?
    }

    var selectedProfileID: UUID?
    var connectionState: AgentConnectionState = .connected(accountName: "Test")
    var connectionModels: [ConnectionModel] = [
        ConnectionModel(
            id: "gpt-test",
            displayName: "Test model",
            isDefault: true,
            supportedReasoningEfforts: ["low", "high"],
            defaultReasoningEffort: "low"
        )
    ]
    var profileSelectedModelID: String? = "gpt-test"
    var automaticReply: String?
    var instructionSources: [String] = []
    var invalidTurnResponse = false
    let credentialSentinel: String
    private(set) var requests: [Request] = []
    private(set) var startedThreadIDs: [String] = []
    private(set) var lastThreadID: String?
    private(set) var lastTurnID: String?

    private var sessionID = UUID()
    private var threadCounter = 0
    private var turnCounter = 0
    private var connectionObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var runtimeObservers: [UUID: @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void] = [:]
    private var dynamicToolHandler: (@MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult)?
    private var dynamicToolHandlerToken: UUID?

    init(profileID: UUID = UUID(), credentialSentinel: String = "unused-secret") {
        selectedProfileID = profileID
        self.credentialSentinel = credentialSentinel
    }

    func addConnectionObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        connectionObservers[id] = observer
        return id
    }

    func removeConnectionObserver(_ id: UUID) {
        connectionObservers.removeValue(forKey: id)
    }

    func addRuntimeObserver(
        _ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void
    ) -> UUID {
        let id = UUID()
        runtimeObservers[id] = observer
        return id
    }

    func removeRuntimeObserver(_ id: UUID) {
        runtimeObservers.removeValue(forKey: id)
    }

    func setDynamicToolHandler(
        _ handler: @escaping @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult
    ) -> UUID {
        let token = UUID()
        dynamicToolHandlerToken = token
        dynamicToolHandler = handler
        return token
    }

    func removeDynamicToolHandler(_ token: UUID) {
        guard dynamicToolHandlerToken == token else { return }
        dynamicToolHandlerToken = nil
        dynamicToolHandler = nil
    }

    func shutdown() async {}

    func request(
        method: String,
        params: [String: Any],
        expectedProfileID: UUID,
        expectedSessionID: UUID?
    ) async throws -> AgentConnectionRuntimeResponse {
        guard selectedProfileID == expectedProfileID,
              expectedSessionID == nil || expectedSessionID == sessionID else {
            throw AgentConnectionError.cancelled
        }
        requests.append(
            Request(
                method: method,
                params: params,
                expectedProfileID: expectedProfileID,
                expectedSessionID: expectedSessionID
            )
        )
        switch method {
        case "thread/start":
            threadCounter += 1
            let threadID = "thread-\(threadCounter)"
            startedThreadIDs.append(threadID)
            lastThreadID = threadID
            return response([
                "thread": ["id": threadID],
                "instructionSources": instructionSources,
                "sandbox": ["type": "readOnly", "networkAccess": false]
            ])
        case "thread/resume":
            let threadID = params["threadId"] as? String ?? "missing"
            lastThreadID = threadID
            return response([
                "thread": ["id": threadID],
                "instructionSources": instructionSources,
                "sandbox": ["type": "readOnly", "networkAccess": false]
            ])
        case "turn/start":
            turnCounter += 1
            let turnID = "turn-\(turnCounter)"
            let threadID = params["threadId"] as? String ?? "missing"
            lastTurnID = turnID
            if invalidTurnResponse {
                return response(["turn": ["status": "inProgress", "items": []]])
            }
            if let automaticReply {
                let split = automaticReply.index(
                    automaticReply.startIndex,
                    offsetBy: automaticReply.count / 2
                )
                let first = String(automaticReply[..<split])
                let second = String(automaticReply[split...])
                emit(
                    method: "item/agentMessage/delta",
                    params: ["threadId": threadID, "turnId": turnID, "itemId": "item-\(turnID)", "delta": first]
                )
                emit(
                    method: "item/agentMessage/delta",
                    params: ["threadId": threadID, "turnId": turnID, "itemId": "item-\(turnID)", "delta": second]
                )
                emit(
                    method: "turn/completed",
                    params: [
                        "threadId": threadID,
                        "turn": [
                            "id": turnID,
                            "status": "completed",
                            "items": [["id": "item-\(turnID)", "type": "agentMessage", "text": automaticReply]]
                        ]
                    ]
                )
            }
            return response(["turn": ["id": turnID, "status": "inProgress", "items": []]])
        case "turn/interrupt":
            return response([:])
        default:
            throw AgentConnectionError.unavailable("Unexpected test request: \(method)")
        }
    }

    func switchProfile(to profileID: UUID) {
        selectedProfileID = profileID
        sessionID = UUID()
        notifyConnectionObservers()
    }

    func notifyConnectionObservers() {
        for observer in connectionObservers.values { observer() }
    }

    func emit(
        profileID: UUID? = nil,
        method: String,
        params: [String: Any]
    ) {
        guard let sourceProfileID = profileID ?? selectedProfileID else { return }
        let event = AgentConnectionRuntimeEvent(
            profileID: sourceProfileID,
            sessionID: sessionID,
            method: method,
            params: params
        )
        for observer in runtimeObservers.values { observer(event) }
    }

    func invokeFileEdit(
        relativePath: String,
        oldText: String,
        newText: String
    ) async throws -> AgentDynamicToolResult {
        let handler = try XCTUnwrap(dynamicToolHandler)
        let profileID = try XCTUnwrap(selectedProfileID)
        let threadID = try XCTUnwrap(lastThreadID)
        let turnID = try XCTUnwrap(lastTurnID)
        return await handler(
            AgentDynamicToolRequest(
                requestID: .integer(1),
                profileID: profileID,
                sessionID: sessionID,
                threadID: threadID,
                turnID: turnID,
                callID: "call-1",
                namespace: nil,
                toolName: "fs_edit_file",
                arguments: .object([
                    "relative_path": .string(relativePath),
                    "old_text": .string(oldText),
                    "new_text": .string(newText)
                ])
            )
        )
    }

    private func response(_ result: [String: Any]) -> AgentConnectionRuntimeResponse {
        AgentConnectionRuntimeResponse(
            profileID: selectedProfileID!,
            sessionID: sessionID,
            result: result
        )
    }
}
