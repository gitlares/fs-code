import AppKit
import XCTest
@testable import FSCode

@MainActor
final class BinaryPreviewTests: XCTestCase {
    func testOpaqueBinaryOpensReadOnlyClosesAndPreservesDirtyTextTab() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("note.swift")
        try "let value = 1".write(to: textURL, atomically: true, encoding: .utf8)
        let binaryURL = folder.appendingPathComponent("opaque.bin")
        try Data([0, 255, 12, 0, 222]).write(to: binaryURL)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        await editor.open(textURL)
        let text = try XCTUnwrap(descendants(editor, of: NSTextView.self).first)
        text.insertText("// dirty\n", replacementRange: NSRange(location: 0, length: 0))
        await editor.open(binaryURL)
        XCTAssertEqual(editor.activeFileURL, binaryURL.resolvingSymlinksInPath())
        XCTAssertFalse(editor.canSave)
        XCTAssertFalse(editor.canFind)
        let closed = await editor.closeActive()
        XCTAssertTrue(closed)
        XCTAssertEqual(editor.activeFileURL, textURL.resolvingSymlinksInPath())
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    func testQuickLookPolicyKeepsSourceTextAsText() {
        XCTAssertTrue(BinaryFilePreviewView.supportsQuickLook(url: URL(fileURLWithPath: "/tmp/file.pdf")))
        XCTAssertFalse(BinaryFilePreviewView.supportsQuickLook(url: URL(fileURLWithPath: "/tmp/file.swift")))
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
