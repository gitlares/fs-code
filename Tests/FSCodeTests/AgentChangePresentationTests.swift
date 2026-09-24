import AppKit
import AgentConnectionCore
import XCTest
@testable import FSCode

@MainActor
final class AgentChangePresentationTests: XCTestCase {
    func testHunkMarkersRefreshAfterRevertAndKeepOriginalAvailableForInvalidatedBlock() async throws {
        _ = NSApplication.shared
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("File.txt")
        let before = [
            "top", "first old", "keep 1", "keep 2", "keep 3", "keep 4",
            "keep 5", "keep 6", "keep 7", "keep 8", "keep 9", "keep 10",
            "second old", "bottom"
        ].joined(separator: "\n") + "\n"
        let after = before
            .replacingOccurrences(of: "first old", with: "first new")
            .replacingOccurrences(of: "second old", with: "second new")
        try Data(before.utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "File.txt",
            oldText: before,
            newText: after,
            threadID: "thread",
            turnID: "turn"
        )
        let applied = try await service.applyApproved(proposal)
        XCTAssertEqual(applied.changeHunks.count, 2)

        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }
        await editor.open(file)
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL
        editor.setAgentChangeHunks([canonical: applied.changeHunks])
        editor.layoutSubtreeIfNeeded()

        let text = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first)
        XCTAssertEqual(text.agentChangeRanges.count, 2)
        let original = try XCTUnwrap(descendants(editor, of: NSButton.self).first { $0.title == "Original" })
        let revert = try XCTUnwrap(descendants(editor, of: NSButton.self).first { $0.title == "Revert" })
        XCTAssertFalse(original.isHidden)
        XCTAssertTrue(revert.isEnabled)
        XCTAssertLessThanOrEqual(original.convert(original.bounds, to: editor).maxX, editor.bounds.maxX + 0.5)
        XCTAssertLessThanOrEqual(revert.convert(revert.bounds, to: editor).maxX, editor.bounds.maxX + 0.5)

        let first = try XCTUnwrap(applied.changeHunks.first { $0.beforeText.contains("first old") })
        _ = try await service.revertHunk(recordID: applied.id, hunkID: first.id)
        let history = try await service.history()
        let partiallyReverted = try XCTUnwrap(history.first)
        await editor.reloadCleanDocument(at: file)
        editor.setAgentChangeHunks([canonical: partiallyReverted.changeHunks])
        XCTAssertEqual(text.agentChangeRanges.count, 1)

        let second = try XCTUnwrap(partiallyReverted.changeHunks.first { !$0.isReverted })
        let range = try XCTUnwrap(second.locate(in: text.string))
        text.insertText("manual", replacementRange: range)
        await Task.yield()
        editor.setAgentChangeHunks([canonical: partiallyReverted.changeHunks])

        XCTAssertEqual(text.agentChangeRanges.count, 0)
        XCTAssertFalse(original.isHidden, "Original remains available after a user edit invalidates a hunk location")
        XCTAssertFalse(revert.isEnabled)
        XCTAssertEqual(revert.toolTip, "Save or discard your edits before reverting this block.")
    }

    func testZeroLengthEOFHunkIsRetainedForPresentation() async throws {
        _ = NSApplication.shared
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("EOF.txt")
        try Data("line\nremove\n".utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "EOF.txt",
            oldText: "line\nremove\n",
            newText: "line\n",
            threadID: "thread",
            turnID: "delete"
        )
        let applied = try await service.applyApproved(proposal)
        let hunk = try XCTUnwrap(applied.changeHunks.first)
        XCTAssertTrue(hunk.afterText.isEmpty)

        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }
        await editor.open(file)
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL
        editor.setAgentChangeHunks([canonical: applied.changeHunks])
        let text = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first)
        XCTAssertEqual(text.agentChangeRanges, [NSRange(location: text.string.utf16.count, length: 0)])
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
