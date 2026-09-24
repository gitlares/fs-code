import AppKit
import XCTest
@testable import FSCode

@MainActor
final class InlineTodoNavigationTests: XCTestCase {
    func testSelectingLinkedLineKeepsOtherOpenDrafts() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let draftURL = folder.appendingPathComponent("draft.txt")
        let linkedURL = folder.appendingPathComponent("linked.txt")
        try Data("Draft".utf8).write(to: draftURL)
        try Data("first\nsecond\nthird".utf8).write(to: linkedURL)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }

        await editor.open(draftURL)
        let draft = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first { $0.string == "Draft" })
        draft.insertText(" draft", replacementRange: NSRange(location: draft.string.utf16.count, length: 0))
        XCTAssertTrue(editor.hasUnsavedChanges)

        await editor.open(linkedURL)
        editor.select(line: 2)

        XCTAssertEqual(editor.activeFileURL, linkedURL.resolvingSymlinksInPath())
        let linked = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first { $0.string == "first\nsecond\nthird" })
        XCTAssertEqual(linked.selectedRange().location, 6)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
