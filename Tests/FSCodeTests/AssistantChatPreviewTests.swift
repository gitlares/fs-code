import AppKit
import QuartzCore
import XCTest
@testable import AgentConnectionCore
@testable import FSCode

@MainActor
final class AssistantChatPreviewTests: XCTestCase {
    func testRenderChatPreviewArtifactsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["FS_CODE_RENDER_CHAT_PREVIEWS"] == "1" else {
            throw XCTSkip("Set FS_CODE_RENDER_CHAT_PREVIEWS=1 to export CHAT-07 previews.")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/chat07-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for width in [CGFloat(340), CGFloat(760)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: project) }
                let profileID = UUID()
                try writeFixture(project: project, profileID: profileID)
                let conversation = AgentConversationManager(projectURL: project, transport: ChatPreviewTransport(profileID: profileID))
                try await conversation.load()
                conversation.updateDraft("Inspect the active workspace changes.")
                await conversation.send()
                conversation.updateDraft("Queue a concise summary after the active turn.")
                await conversation.send()
                conversation.updateDraft("Queue the follow-up checks after that.")
                await conversation.send()
                XCTAssertEqual(conversation.queuedMessages.count, 2)
                XCTAssertFalse(conversation.messages.contains { $0.text.contains("Queue a concise summary") })
                conversation.updateDraft("Queue one more message.")
                XCTAssertTrue(conversation.canQueue)
                let panel = AssistantChatView(
                    manager: conversation,
                    connectionManager: AgentConnectionManager(applicationSupportURL: project.appendingPathComponent("connections")),
                    projectURL: project,
                    selectedProfileID: { profileID },
                    onAddConnection: {},
                    onManageConnections: { _ in }
                )
                panel.appearance = NSAppearance(named: appearance)
                panel.frame = NSRect(x: 0, y: 0, width: width, height: 720)
                let window = NSWindow(
                    contentRect: panel.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = panel
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(120))
                panel.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                panel.displayIfNeeded()
                CATransaction.flush()
                await Task.yield()
                panel.layoutSubtreeIfNeeded()
                let table = try XCTUnwrap(descendants(panel, of: NSTableView.self).first)
                let collapsedHeight = table.rect(ofRow: 0).height
                let composer = try XCTUnwrap(descendants(panel, of: NSTextView.self)
                    .first { $0.accessibilityLabel() == "Message composer" })
                XCTAssertEqual(composer.accessibilityHelp(), "Enter to send. Shift-Enter inserts a new line.")
                XCTAssertTrue(composer.isEditable)
                let tabButton = try XCTUnwrap(descendants(panel, of: NSButton.self).first { $0.title == "Review workspace" })
                XCTAssertGreaterThan(tabButton.frame.width, 50)
                let selectors = descendants(panel, of: NSButton.self).filter {
                    ["Chat model", "Reasoning effort", "Last request input context"].contains($0.accessibilityLabel())
                }
                XCTAssertEqual(selectors.count, 3)
                XCTAssertTrue(selectors.allSatisfy { !$0.isBordered })
                let queued = try XCTUnwrap(descendants(panel, of: NSTextField.self)
                    .first { $0.accessibilityLabel() == "Queued message" })
                XCTAssertTrue(queued.stringValue.contains("Queue a concise summary"))
                let steer = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Steer queued message" })
                XCTAssertTrue(steer.isEnabled)
                let remove = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Remove queued message" })
                XCTAssertTrue(remove.isEnabled)
                let queueSend = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Queue message" })
                XCTAssertTrue(queueSend.isEnabled)
                let stop = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Stop response" })
                XCTAssertFalse(stop.isHidden)
                conversation.updateDraft("Queue from Return")
                composer.keyDown(with: try returnEvent(window: window))
                try await Task.sleep(for: .milliseconds(120))
                XCTAssertEqual(conversation.queuedMessages.filter { $0.text == "Queue from Return" }.count, 1)
                let queueCountAfterReturn = conversation.queuedMessages.count
                composer.string = "Shift newline"
                composer.keyDown(with: try returnEvent(window: window, modifiers: .shift))
                XCTAssertEqual(composer.string, "Shift newline\n")
                XCTAssertEqual(conversation.queuedMessages.count, queueCountAfterReturn)
                composer.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                composer.keyDown(with: try returnEvent(window: window))
                XCTAssertEqual(conversation.queuedMessages.count, queueCountAfterReturn)
                composer.unmarkText()
                let effort = try XCTUnwrap(selectors.first { $0.accessibilityLabel() == "Reasoning effort" })
                XCTAssertGreaterThanOrEqual(effort.frame.width + 0.5, effort.fittingSize.width)
                if width == 340 {
                    let context = try XCTUnwrap(selectors.first { $0.accessibilityLabel() == "Last request input context" })
                    XCTAssertTrue(context.title.isEmpty)
                    XCTAssertTrue(context.toolTip?.contains("31744 of 128000 tokens") == true)
                    XCTAssertEqual(context.accessibilityValue() as? String, "25%")
                    let controls = selectors + [try XCTUnwrap(descendants(panel, of: NSButton.self)
                        .first { $0.accessibilityLabel() == "Connection" })]
                    XCTAssertTrue(controls.allSatisfy { $0.frame.maxX <= panel.bounds.width + 0.5 })
                    XCTAssertEqual(Set(controls.map { $0.frame.midY.rounded() }).count, 1)
                    XCTAssertLessThanOrEqual(steer.convert(steer.bounds, to: panel).maxX, panel.bounds.width + 0.5)
                }
                try writeSnapshot(panel, to: output, named: "chat-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light")-collapsed.png")
                let disclosure = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel()?.hasPrefix("Turn activity:") == true })
                disclosure.performClick(nil)
                panel.layoutSubtreeIfNeeded()
                table.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(table.rect(ofRow: 0).height, collapsedHeight + 80)
                XCTAssertTrue(descendants(panel, of: NSTextView.self).contains { $0.string.contains("AssistantChatView.swift") })
                try writeSnapshot(panel, to: output, named: "chat-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light")-expanded.png")
                steer.performClick(nil)
                try await Task.sleep(for: .milliseconds(120))
                XCTAssertEqual(conversation.queuedMessages.count, queueCountAfterReturn - 1)
                XCTAssertTrue(conversation.messages.contains { $0.text.contains("Queue a concise summary") })

                stop.performClick(nil)
                try await Task.sleep(for: .milliseconds(120))
                XCTAssertTrue(conversation.queueIsPaused)
                let resume = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Resume queued messages" && !$0.isHidden })
                resume.performClick(nil)
                try await Task.sleep(for: .milliseconds(120))
                XCTAssertFalse(conversation.queueIsPaused)

                let remainingRemove = try XCTUnwrap(descendants(panel, of: NSButton.self)
                    .first { $0.accessibilityLabel() == "Remove queued message" })
                remainingRemove.performClick(nil)
                try await Task.sleep(for: .milliseconds(120))
                XCTAssertEqual(conversation.queuedMessages.count, queueCountAfterReturn - 2)
            }
        }
    }

    func testSendingFromEarlierTranscriptRevealsTheNewUserMessage() async throws {
        _ = NSApplication.shared
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let profileID = UUID()
        try writeFixture(project: project, profileID: profileID, longHistory: true)
        let conversation = AgentConversationManager(projectURL: project, transport: ChatPreviewTransport(profileID: profileID))
        try await conversation.load()
        let panel = AssistantChatView(
            manager: conversation,
            connectionManager: AgentConnectionManager(applicationSupportURL: project.appendingPathComponent("connections")),
            projectURL: project,
            selectedProfileID: { profileID },
            onAddConnection: {},
            onManageConnections: { _ in }
        )
        panel.frame = NSRect(x: 0, y: 0, width: 420, height: 680)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        panel.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(panel, of: NSTableView.self).first)
        table.scrollRowToVisible(0)
        let composer = try XCTUnwrap(descendants(panel, of: NSTextView.self)
            .first { $0.accessibilityLabel() == "Message composer" })
        composer.string = "Reveal this newly sent message"
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        let send = try XCTUnwrap(descendants(panel, of: NSButton.self)
            .first { $0.accessibilityLabel() == "Send message" })
        send.performClick(nil)
        for _ in 0..<80 where !conversation.messages.contains(where: { $0.text == "Reveal this newly sent message" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(conversation.messages.contains { $0.text == "Reveal this newly sent message" })
        try await Task.sleep(for: .milliseconds(120))
        panel.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(conversation.messages.lastIndex { $0.text == "Reveal this newly sent message" })
        let rowRect = table.rect(ofRow: row)
        XCTAssertTrue(
            rowRect.height <= table.visibleRect.height
                ? table.visibleRect.contains(rowRect)
                : table.visibleRect.intersects(rowRect)
        )
    }

    func testRuntimeSummaryIsReplacedByCommentaryAndFinalAnswer() async throws {
        _ = NSApplication.shared
        let previewOutput: URL?
        if ProcessInfo.processInfo.environment["FS_CODE_RENDER_CHAT_PREVIEWS"] == "1" {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/chat09-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            previewOutput = output
        } else {
            previewOutput = nil
        }
        for width in [CGFloat(340), CGFloat(760)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let appearanceName = appearance == .darkAqua ? "dark" : "light"
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let profileID = UUID()
        try writeFixture(project: project, profileID: profileID)
        let transport = ChatPreviewTransport(profileID: profileID)
        let conversation = AgentConversationManager(projectURL: project, transport: transport)
        try await conversation.load()
        let panel = AssistantChatView(
            manager: conversation,
            connectionManager: AgentConnectionManager(applicationSupportURL: project.appendingPathComponent("connections")),
            projectURL: project,
            selectedProfileID: { profileID },
            onAddConnection: {},
            onManageConnections: { _ in }
        )
        panel.appearance = NSAppearance(named: appearance)
        panel.frame = NSRect(x: 0, y: 0, width: width, height: 680)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))

        conversation.updateDraft("Show runtime progress")
        await conversation.send()
        let userID = try XCTUnwrap(conversation.messages.last?.id)
        transport.emit(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": "preview-thread", "turnId": "preview-active-turn", "itemId": "reasoning",
            "summaryIndex": 0, "delta": "Checking https://example.com/Sources/FSCode/AssistantChatView.swift"
        ])
        try await Task.sleep(for: .milliseconds(120))
        let thinking = try XCTUnwrap(descendants(panel, of: NSTextField.self)
            .first { $0.accessibilityLabel() == "Thinking" })
        XCTAssertTrue(thinking.stringValue.contains("Checking"))
        XCTAssertLessThanOrEqual(thinking.convert(thinking.bounds, to: panel).maxX, panel.bounds.maxX + 0.5)
        XCTAssertGreaterThan(thinking.frame.height, 0)
        let table = try XCTUnwrap(descendants(panel, of: NSTableView.self).first)
        let progressRow = table.numberOfRows - 1
        let initialRowHeight = table.rect(ofRow: progressRow).height
        let request = try XCTUnwrap(descendants(panel, of: NSTextField.self)
            .first { $0.stringValue == "Show runtime progress" })
        XCTAssertLessThanOrEqual(request.convert(request.bounds, to: panel).maxX, panel.bounds.maxX + 0.5)
        if let previewOutput {
            try writeSnapshot(panel, to: previewOutput, named: "chat09-progress-\(Int(width))-\(appearanceName).png")
        }
        let resizedWidth: CGFloat = width == 340 ? 760 : 340
        window.setContentSize(NSSize(width: resizedWidth, height: 680))
        panel.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: progressRow).height, 0)
        XCTAssertGreaterThan(initialRowHeight, 0)
        XCTAssertLessThanOrEqual(thinking.convert(thinking.bounds, to: panel).maxX, panel.bounds.maxX + 0.5)
        XCTAssertLessThanOrEqual(request.convert(request.bounds, to: panel).maxX, panel.bounds.maxX + 0.5)
        window.setContentSize(NSSize(width: width, height: 680))
        panel.layoutSubtreeIfNeeded()

        transport.emit(method: "item/started", params: [
            "threadId": "preview-thread", "turnId": "preview-active-turn",
            "item": ["id": "commentary", "type": "agentMessage", "phase": "commentary"]
        ])
        transport.emit(method: "item/agentMessage/delta", params: [
            "threadId": "preview-thread", "turnId": "preview-active-turn", "itemId": "commentary",
            "delta": "Working with https://example.com and `Sources/FSCode/AssistantChatView.swift`."
        ])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(descendants(panel, of: NSTextField.self).first { $0.accessibilityLabel() == "Thinking" })
        let commentary = try XCTUnwrap(descendants(panel, of: NSTextView.self).first { $0.string.contains("Working with") })
        XCTAssertEqual(commentary.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)

        transport.emit(method: "item/started", params: [
            "threadId": "preview-thread", "turnId": "preview-active-turn",
            "item": ["id": "final", "type": "agentMessage", "phase": "final_answer"]
        ])
        transport.emit(method: "item/completed", params: [
            "threadId": "preview-thread", "turnId": "preview-active-turn",
            "item": ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": "Final answer with https://example.org. This deliberately long response verifies that the native transcript reflows its text after the assistant panel is resized from narrow to wide and back again."]
        ])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(conversation.liveProgressText)
        let final = try XCTUnwrap(descendants(panel, of: NSTextView.self).first { $0.string.contains("Final answer") })
        XCTAssertEqual(final.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        let finalRow = table.numberOfRows - 1
        panel.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: finalRow)), "A streamed response stays followed after its asynchronous row measurement")
        var rowHeights: [CGFloat] = []
        var responseWidths: [CGFloat] = []
        for responseWidth: CGFloat in [340, 760, 340, 760, 340] {
            window.setContentSize(NSSize(width: responseWidth, height: 680))
            panel.layoutSubtreeIfNeeded()
            var previousHeight: CGFloat?
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(25))
                panel.layoutSubtreeIfNeeded()
                table.layoutSubtreeIfNeeded()
                let measured = table.rect(ofRow: finalRow).height
                if let previousHeight, abs(previousHeight - measured) < 0.5 { break }
                previousHeight = measured
            }
            let reflowed = try XCTUnwrap(descendants(panel, of: NSTextView.self).first { $0.string.contains("Final answer") })
            XCTAssertGreaterThan(reflowed.bounds.width, 100)
            responseWidths.append(reflowed.bounds.width)
            XCTAssertLessThanOrEqual(reflowed.convert(reflowed.bounds, to: panel).maxX, panel.bounds.maxX + 0.5)
            XCTAssertEqual(reflowed.textContainer?.containerSize.width ?? 0, reflowed.bounds.width, accuracy: 1)
            let used = reflowed.layoutManager?.usedRect(for: try XCTUnwrap(reflowed.textContainer)).height ?? 0
            XCTAssertGreaterThanOrEqual(reflowed.bounds.height + 0.5, used)
            rowHeights.append(table.rect(ofRow: finalRow).height)
        }
        XCTAssertGreaterThan(rowHeights[0], rowHeights[1])
        XCTAssertGreaterThan(rowHeights[2], rowHeights[3])
        XCTAssertGreaterThan(responseWidths[1], responseWidths[0])
        XCTAssertEqual(conversation.messages.last?.phase, .finalAnswer)
        XCTAssertEqual(conversation.messages.first(where: { $0.id == userID })?.role, .user)
        transport.emit(method: "turn/completed", params: [
            "threadId": "preview-thread",
            "turn": ["id": "preview-active-turn", "status": "completed", "items": []]
        ])
        try await Task.sleep(for: .milliseconds(120))
        panel.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(table.numberOfRows - 1)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: table.numberOfRows - 1)))
        if let previewOutput {
            try writeSnapshot(panel, to: previewOutput, named: "chat09-final-\(Int(width))-\(appearanceName).png")
        }
            }
        }
    }

    func testTranscriptResizeKeepsBottomOrReaderPosition() async throws {
        _ = NSApplication.shared
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let profileID = UUID()
        try writeFixture(project: project, profileID: profileID, longHistory: true)
        let manager = AgentConversationManager(projectURL: project, transport: ChatPreviewTransport(profileID: profileID))
        try await manager.load()
        let panel = AssistantChatView(manager: manager, connectionManager: AgentConnectionManager(applicationSupportURL: project.appendingPathComponent("connections")), projectURL: project, selectedProfileID: { profileID }, onAddConnection: {}, onManageConnections: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try XCTUnwrap(descendants(panel, of: NSTableView.self).first)
        let scroll = try XCTUnwrap(descendants(panel, of: NSScrollView.self).first { $0.documentView === table })
        func settle(_ width: CGFloat) async throws {
            window.setContentSize(NSSize(width: width, height: 600))
            var prior: CGFloat?
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(20))
                panel.layoutSubtreeIfNeeded()
                let height = table.rect(ofRow: table.numberOfRows - 1).height
                if let prior, abs(prior - height) < 0.5 { break }
                prior = height
            }
        }
        table.scrollRowToVisible(table.numberOfRows - 1)
        try await settle(700)
        let bottomDistance = max(0, table.rect(ofRow: table.numberOfRows - 1).maxY - table.visibleRect.maxY)
        XCTAssertLessThanOrEqual(bottomDistance, 1)
        table.scrollRowToVisible(4)
        let before = table.row(at: NSPoint(x: 4, y: table.visibleRect.minY + 2))
        let beforeOffset = table.visibleRect.minY - table.rect(ofRow: before).minY
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        await Task.yield()
        try await settle(420)
        let after = table.row(at: NSPoint(x: 4, y: table.visibleRect.minY + 2))
        XCTAssertEqual(after, before)
        XCTAssertEqual(table.visibleRect.minY - table.rect(ofRow: after).minY, beforeOffset, accuracy: 2)
    }

    private func writeFixture(project: URL, profileID: UUID, longHistory: Bool = false) throws {
        let userID = UUID()
        let threadID = UUID()
        let now = Date()
        var messages = [
            ConversationMessage(id: userID, role: .user, text: "Inspect the editor layout and summarize the relevant changes.", createdAt: now.addingTimeInterval(-80)),
            ConversationMessage(role: .assistant, text: "The layout keeps the **editor central** and makes the assistant easier to scan. See https://example.com/very/long/path/that/wraps/in/a/narrow/transcript and `Sources/FSCode/AssistantChatView.swift`.\n\n- Controls stay beside the composer.\n- Runtime work is attached to the request.\n- Context reflects the latest request.", createdAt: now.addingTimeInterval(-60), phase: .finalAnswer),
            ConversationMessage(role: .user, text: "Keep the activity readable at the minimum assistant width.", createdAt: now.addingTimeInterval(-40)),
            ConversationMessage(role: .assistant, text: "Done. Commands and output remain selectable in a bounded scrolling region.", createdAt: now.addingTimeInterval(-20))
        ]
        if longHistory {
            for index in 0..<30 {
                messages.append(ConversationMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Earlier transcript message \(index) with enough content to form a visible row.", createdAt: now.addingTimeInterval(Double(index))))
            }
        }
        let conversation = PreviewConversation(
            id: threadID, profileID: profileID, remoteThreadID: "preview-thread", lastRemoteTurnID: "preview-turn",
            dynamicToolsVersion: 1, title: "Review workspace", createdAt: now.addingTimeInterval(-90), updatedAt: now,
            modelID: "gpt-5.6-sol", reasoningEffort: ConversationReasoningEffort(rawValue: "xhigh"), draft: "",
            messages: messages,
            inputContextUsage: ConversationInputContextUsage(inputTokens: 31_744, modelContextWindow: 128_000, modelID: "gpt-5.6-sol"),
            activitySummaries: [ConversationTurnActivitySummary(userMessageID: userID, remoteTurnID: "preview-turn", activities: [
                ConversationTurnActivity(itemID: "reasoning", phase: .reasoning, status: "completed", startedAt: now.addingTimeInterval(-78), completedAt: now.addingTimeInterval(-76)),
                ConversationTurnActivity(itemID: "command", phase: .command, operation: "rg -n AssistantChatView Sources/FSCode", status: "completed", output: "Sources/FSCode/AssistantChatView.swift:5:final class AssistantChatView\nSources/FSCode/AssistantConnectionView.swift:32:chatView = AssistantChatView(…)", startedAt: now.addingTimeInterval(-75), completedAt: now.addingTimeInterval(-73)),
                ConversationTurnActivity(itemID: "tool", phase: .dynamicTool, operation: "Inspect native layout constraints", status: "completed", output: "Verified compact and wide composer arrangements.", startedAt: now.addingTimeInterval(-72), completedAt: now.addingTimeInterval(-71))
            ])]
        )
        let document = PreviewDocument(version: 1, projectPath: project.resolvingSymlinksInPath().standardizedFileURL.path, selectedThreadIDs: [profileID.uuidString: threadID], conversations: [conversation])
        let directory = project.appendingPathComponent(".fscode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: directory.appendingPathComponent("conversations.json"))
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    private func writeSnapshot(_ panel: NSView, to output: URL, named name: String) throws {
        panel.displayIfNeeded()
        CATransaction.flush()
        let bitmap = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name))
    }

    private func returnEvent(window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
    }
}

private struct PreviewDocument: Codable {
    var version: Int; var projectPath: String; var selectedThreadIDs: [String: UUID]; var conversations: [PreviewConversation]
}

private struct PreviewConversation: Codable {
    var id: UUID; var profileID: UUID; var remoteThreadID: String?; var lastRemoteTurnID: String?; var dynamicToolsVersion: Int?
    var title: String; var createdAt: Date; var updatedAt: Date; var modelID: String?; var reasoningEffort: ConversationReasoningEffort?
    var draft: String; var messages: [ConversationMessage]; var inputContextUsage: ConversationInputContextUsage?
    var activitySummaries: [ConversationTurnActivitySummary]?
}

@MainActor
private final class ChatPreviewTransport: AgentConversationTransport {
    let selectedProfileID: UUID?
    let connectionState: AgentConnectionState = .connected(accountName: "Daniella")
    let connectionModels = [
        ConnectionModel(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", isDefault: true, supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], defaultReasoningEffort: "xhigh"),
        ConnectionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", isDefault: false, supportedReasoningEfforts: ["low", "medium", "high"], defaultReasoningEffort: "medium"),
        ConnectionModel(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", isDefault: false, supportedReasoningEfforts: ["low", "medium"], defaultReasoningEffort: "medium")
    ]
    let profileSelectedModelID: String? = "gpt-5.6-sol"
    private let sessionID = UUID()
    private var connectionObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var runtimeObservers: [UUID: @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void] = [:]
    init(profileID: UUID) { selectedProfileID = profileID }
    func addConnectionObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID { let id = UUID(); connectionObservers[id] = observer; return id }
    func removeConnectionObserver(_ id: UUID) { connectionObservers[id] = nil }
    func addRuntimeObserver(_ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void) -> UUID { let id = UUID(); runtimeObservers[id] = observer; return id }
    func removeRuntimeObserver(_ id: UUID) { runtimeObservers[id] = nil }
    func emit(method: String, params: [String: Any]) {
        for observer in runtimeObservers.values {
            observer(AgentConnectionRuntimeEvent(profileID: selectedProfileID ?? UUID(), sessionID: sessionID, method: method, params: params))
        }
    }
    func setDynamicToolHandler(_ handler: @escaping @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult) -> UUID { UUID() }
    func removeDynamicToolHandler(_ token: UUID) {}
    func shutdown() async {}
    func request(method: String, params: [String: Any], expectedProfileID: UUID, expectedSessionID: UUID?) async throws -> AgentConnectionRuntimeResponse {
        switch method {
        case "thread/start", "thread/resume":
            AgentConnectionRuntimeResponse(
                profileID: expectedProfileID,
                sessionID: sessionID,
                result: [
                    "thread": ["id": "preview-thread"],
                    "sandbox": ["type": "readOnly", "networkAccess": false]
                ]
            )
        case "turn/start":
            AgentConnectionRuntimeResponse(
                profileID: expectedProfileID,
                sessionID: sessionID,
                result: ["turn": ["id": "preview-active-turn"]]
            )
        case "turn/steer":
            AgentConnectionRuntimeResponse(
                profileID: expectedProfileID,
                sessionID: sessionID,
                result: ["turnId": "preview-active-turn"]
            )
        default:
            AgentConnectionRuntimeResponse(profileID: expectedProfileID, sessionID: sessionID, result: [:])
        }
    }
}
