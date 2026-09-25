import AppKit
import EditorCore
import XCTest
@testable import FSCode

@MainActor
final class EditorThemeIntegrationTests: XCTestCase {
    func testBundledPalettesPreserveEditorRolesAndTerminalANSI() {
        assertBuiltin(
            .dracula,
            editor: ["282A36", "F8F8F2", "44475A", "6272A4", "6272A4", "BD93F9"],
            tokens: ["FF79C6", "FF79C6", "FF79C6", "F1FA8C", "6272A4", "BD93F9", "8BE9FD", "50FA7B", "50FA7B", "50FA7B"],
            ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2", "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]
        )
        XCTAssertEqual(EditorPalette(theme: .dracula).currentLine.alphaComponent, 0.35, accuracy: 0.0001)
        XCTAssertEqual(EditorPalette(theme: .alucard).currentLine.alphaComponent, 0.35, accuracy: 0.0001)
        assertBuiltin(
            .alucard,
            editor: ["FFFBEB", "1F1F1F", "CFCFDE", "6C664B", "6C664B", "644AC9"],
            tokens: ["A3144D", "A3144D", "A3144D", "846E15", "6C664B", "644AC9", "036A96", "14710A", "14710A", "14710A"],
            ansi: ["1F1F1F", "B3261E", "14710A", "846E15", "644AC9", "A3144D", "036A96", "FFFBEB", "6C664B", "D34038", "258C1B", "A88916", "7958DC", "C33A70", "087FAF", "FFFFFF"]
        )
    }

    func testAppearanceThemeSwitchPreservesFontSelectionAndUndo() async throws {
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
        let font = text.font
        let selection = NSRange(location: 4, length: 5)
        text.setSelectedRange(selection)
        let original = text.string
        let undoBefore = text.undoManager?.canUndo

        window.appearance = NSAppearance(named: .darkAqua)
        text.viewDidChangeEffectiveAppearance()
        await Task.yield()

        XCTAssertEqual(text.string, original)
        XCTAssertEqual(text.font, font)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(text.undoManager?.canUndo, undoBefore)
    }

    func testThemeChangeDuringInitialLexingCannotApplyStaleColors() async throws {
        _ = NSApplication.shared
        let store = EditorThemeStore.shared
        let oldLight = store.selectedThemeID(for: .light)
        let oldDark = store.selectedThemeID(for: .dark)
        defer {
            store.setSelectedThemeID(oldLight, for: .light)
            store.setSelectedThemeID(oldDark, for: .dark)
        }
        store.setSelectedThemeID(EditorTheme.alucard.id, for: .light)
        store.setSelectedThemeID(EditorTheme.dracula.id, for: .dark)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Race.swift")
        try Data("let first = 1\n".utf8).write(to: file)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        await editor.open(file)
        let text = try XCTUnwrap(descendants(editor, of: CodeTextView.self).first)

        window.appearance = NSAppearance(named: .aqua)
        text.viewDidChangeEffectiveAppearance()
        text.insertText("// edited\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        window.appearance = NSAppearance(named: .darkAqua)
        text.viewDidChangeEffectiveAppearance()
        try await Task.sleep(nanoseconds: 260_000_000)

        XCTAssertTrue(text.string.contains("// edited"))
        XCTAssertEqual(text.backgroundColor, EditorPalette(theme: .dracula).background)
        let keywordRange = (text.string as NSString).range(of: "let")
        XCTAssertEqual(
            text.textStorage?.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor,
            EditorPalette(theme: .dracula).color(for: .keyword)
        )
    }

    func testThemeSwitchRecolorsCachedTokensWithoutTokenizingAgain() async throws {
        _ = NSApplication.shared
        let store = EditorThemeStore.shared
        let oldLight = store.selectedThemeID(for: .light)
        let oldDark = store.selectedThemeID(for: .dark)
        defer {
            store.setSelectedThemeID(oldLight, for: .light)
            store.setSelectedThemeID(oldDark, for: .dark)
        }
        store.setSelectedThemeID(EditorTheme.alucard.id, for: .light)
        store.setSelectedThemeID(EditorTheme.dracula.id, for: .dark)

        let text = CodeTextView(usingTextLayoutManager: true)
        text.string = "let value = 1\n"
        let scroll = NSScrollView()
        scroll.documentView = text
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let presentation = CodePresentation(textView: text, scrollView: scroll, url: URL(fileURLWithPath: "/tmp/Theme.swift"))
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(presentation.tokenizationCount, 1)

        window.appearance = NSAppearance(named: .darkAqua)
        text.viewDidChangeEffectiveAppearance()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(presentation.tokenizationCount, 1)
        XCTAssertEqual(text.backgroundColor, EditorPalette(theme: .dracula).background)
    }

    private func assertBuiltin(
        _ theme: EditorTheme,
        editor: [String],
        tokens: [String],
        ansi: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let palette = EditorPalette(theme: theme)
        XCTAssertEqual(
            [palette.background, palette.foreground, palette.currentLine, palette.comment, palette.currentLineNumber, palette.cursor].map(hex),
            editor,
            file: file,
            line: line
        )
        let kinds: [SyntaxTokenKind] = [.keyword, .operator, .tag, .string, .comment, .number, .type, .function, .property, .attribute]
        XCTAssertEqual(kinds.map { hex(palette.color(for: $0)) }, tokens, file: file, line: line)
        XCTAssertEqual(palette.ansiColors.map(hex), ansi, file: file, line: line)
    }

    private func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
