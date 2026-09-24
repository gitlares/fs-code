import AppKit
import ProjectLibrary
import XCTest
@testable import FSCode

@MainActor final class WorkspaceLayoutTests: XCTestCase {
    private func makeWorkspace() throws -> (WorkspaceWindow, URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(id: UUID(), name: "Layout Test", path: folder.path)
        let workspace = WorkspaceWindow(project: project, url: folder, launchesTerminal: false)
        workspace.window.makeKeyAndOrderFront(nil)
        return (workspace, folder)
    }

    private func settle(_ workspace: WorkspaceWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        (workspace.window.contentViewController as? NSSplitViewController)?.splitView.adjustSubviews()
    }

    private func splits(_ workspace: WorkspaceWindow) throws -> (NSSplitViewController, NSSplitViewController) {
        let workspaceSplit = try XCTUnwrap(workspace.window.contentViewController as? NSSplitViewController)
        let editorSplit = try XCTUnwrap(workspaceSplit.splitViewItems[1].viewController as? NSSplitViewController)
        return (workspaceSplit, editorSplit)
    }

    func testTerminalHideShowAndReopenKeepLastExpandedHeight() async throws {
        let (workspace, folder) = try makeWorkspace()
        defer {
            workspace.window.close()
            try? FileManager.default.removeItem(at: folder)
        }
        await settle(workspace)
        let (workspaceSplit, editorSplit) = try splits(workspace)
        workspaceSplit.splitView.setPosition(275, ofDividerAt: 0)
        workspaceSplit.splitView.setPosition(
            workspaceSplit.splitView.bounds.width - 350 - workspaceSplit.splitView.dividerThickness,
            ofDividerAt: 1
        )
        editorSplit.splitView.setPosition(
            editorSplit.splitView.bounds.height - 310 - editorSplit.splitView.dividerThickness,
            ofDividerAt: 0
        )
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        let sidebarWidth = workspaceSplit.splitView.arrangedSubviews[0].frame.width
        let assistantWidth = workspaceSplit.splitView.arrangedSubviews[2].frame.width
        let terminalHeight = editorSplit.splitView.arrangedSubviews[1].frame.height
        XCTAssertGreaterThan(sidebarWidth, 250)
        XCTAssertEqual(assistantWidth, 350, accuracy: 1)
        XCTAssertEqual(terminalHeight, 310, accuracy: 1)

        workspace.toggleTerminal()
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        workspace.toggleTerminal()
        workspace.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(editorSplit.splitView.arrangedSubviews[1].frame.height, terminalHeight, accuracy: 1)

        workspace.saveLayout()
        workspace.toggleTerminal()
        workspace.saveLayout()

        let reopened = WorkspaceWindow(
            project: Project(id: UUID(), name: "Layout Test", path: folder.path),
            url: folder,
            launchesTerminal: false
        )
        defer { reopened.window.close() }
        await settle(reopened)
        let (reopenedWorkspaceSplit, reopenedEditorSplit) = try splits(reopened)

        XCTAssertEqual(reopenedWorkspaceSplit.splitView.arrangedSubviews[0].frame.width, sidebarWidth, accuracy: 1)
        XCTAssertEqual(reopenedWorkspaceSplit.splitView.arrangedSubviews[2].frame.width, assistantWidth, accuracy: 1)
        XCTAssertEqual(reopenedEditorSplit.splitView.arrangedSubviews[1].frame.height, terminalHeight, accuracy: 1)
        reopened.saveLayout()

        let reopenedAgain = WorkspaceWindow(
            project: Project(id: UUID(), name: "Layout Test", path: folder.path),
            url: folder,
            launchesTerminal: false
        )
        defer { reopenedAgain.window.close() }
        await settle(reopenedAgain)
        let (againWorkspaceSplit, againEditorSplit) = try splits(reopenedAgain)
        XCTAssertEqual(againWorkspaceSplit.splitView.arrangedSubviews[0].frame.width, sidebarWidth, accuracy: 1)
        XCTAssertEqual(againWorkspaceSplit.splitView.arrangedSubviews[2].frame.width, assistantWidth, accuracy: 1)
        XCTAssertEqual(againEditorSplit.splitView.arrangedSubviews[1].frame.height, terminalHeight, accuracy: 1)
    }

    func testAssistantCanGrowPastFormerMaximumAndRestoresWithoutShrinkingEditor() async throws {
        let (workspace, folder) = try makeWorkspace()
        defer {
            workspace.window.close()
            try? FileManager.default.removeItem(at: folder)
        }
        await settle(workspace)
        let (workspaceSplit, _) = try splits(workspace)
        workspaceSplit.splitView.setPosition(240, ofDividerAt: 0)
        workspaceSplit.splitView.setPosition(
            workspaceSplit.splitView.bounds.width - 520 - workspaceSplit.splitView.dividerThickness,
            ofDividerAt: 1
        )
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspaceSplit.splitView.arrangedSubviews[2].frame.width, 520, accuracy: 1)
        XCTAssertGreaterThanOrEqual(workspaceSplit.splitView.arrangedSubviews[1].frame.width, 340)

        workspace.saveLayout()
        let reopened = WorkspaceWindow(
            project: Project(id: UUID(), name: "Layout Test", path: folder.path),
            url: folder,
            launchesTerminal: false
        )
        defer { reopened.window.close() }
        await settle(reopened)
        let (reopenedSplit, _) = try splits(reopened)
        XCTAssertEqual(reopenedSplit.splitView.arrangedSubviews[2].frame.width, 520, accuracy: 1)
        XCTAssertGreaterThanOrEqual(reopenedSplit.splitView.arrangedSubviews[1].frame.width, 340)
    }
}
