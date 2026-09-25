import AppKit
import XCTest
@testable import FSCode

@MainActor
final class EditorAppearanceTests: XCTestCase {
    func testAppearanceChangesThemeWithoutChangingTextOrUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Theme.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        await editor.open(file)
        let text = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first)
        let original = text.string
        window.appearance = NSAppearance(named: .aqua)
        text.viewDidChangeEffectiveAppearance()
        let lightBackground = text.backgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        text.viewDidChangeEffectiveAppearance()
        XCTAssertNotEqual(lightBackground, text.backgroundColor)
        XCTAssertEqual(text.string, original)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(text.undoManager?.canUndo ?? true)
    }

    func testFocusedAndUnfocusedSelectionUseSystemSemanticColors() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Selection.txt")
        try Data("selection\n".utf8).write(to: file)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        await editor.open(file)
        let text = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first)
        // Headless XCTest cannot make a window key reliably. Exercise the exact callback used by
        // the responder/key-window lifecycle, with the real system semantic colors.
        text.onSelectionFocusChange?(true)
        let focused = text.selectedTextAttributes[.backgroundColor] as? NSColor
        XCTAssertEqual(focused, NSColor.selectedTextBackgroundColor)
        text.onSelectionFocusChange?(false)
        let unfocused = text.selectedTextAttributes[.backgroundColor] as? NSColor
        XCTAssertEqual(unfocused, NSColor.unemphasizedSelectedTextBackgroundColor)

        text.onSelectionFocusChange?(true)
        text.onSelectionFocusChange?(false) // didResignKey while first responder remains the editor.
        let resigned = text.selectedTextAttributes[.backgroundColor] as? NSColor
        XCTAssertEqual(resigned, NSColor.unemphasizedSelectedTextBackgroundColor)
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
