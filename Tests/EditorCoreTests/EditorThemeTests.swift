import Foundation
import XCTest
@testable import EditorCore

@MainActor
final class EditorThemeTests: XCTestCase {
    func testCurrentFormatAcceptsQuotedHashAndMixedCaseKeys() throws {
        let yaml = """
        system: "base16"
        name: "Modern"
        author: "Ada"
        variant: "DARK"
        palette:
        \(palette(indent: "  ", quotedHash: true, mixedCase: true))
        """
        let theme = try Base16ThemeImporter.parse(yaml: yaml, id: "modern")
        XCTAssertEqual(theme.id, "modern")
        XCTAssertEqual(theme.name, "Modern")
        XCTAssertEqual(theme.author, "Ada")
        XCTAssertEqual(theme.variant, .dark)
        XCTAssertEqual(theme.background.hex, "000000")
        XCTAssertEqual(theme.foreground.hex, "050505")
    }

    func testLegacyFormatClassifiesLuminanceAndVariantOverridesIt() throws {
        let light = "scheme: Legacy\n" + palette().replacingOccurrences(of: "base00: 000000", with: "base00: FFFFFF")
        XCTAssertEqual(try Base16ThemeImporter.parse(yaml: light).variant, .light)
        let forcedDark = "scheme: Forced\nvariant: dark\n" + palette().replacingOccurrences(of: "base00: 000000", with: "base00: FFFFFF")
        XCTAssertEqual(try Base16ThemeImporter.parse(yaml: forcedDark).variant, .dark)
    }

    func testErrorsNameTheExactProblem() {
        assertParseError("", contains: "empty")
        assertParseError("scheme: Missing\n" + palette().replacingOccurrences(of: "base0F: 0F0F0F\n", with: ""), contains: "base0F")
        assertParseError("scheme: Invalid\n" + palette().replacingOccurrences(of: "base00: 000000", with: "base00: GG0000"), contains: "GG0000")
        assertParseError("- base00: 000000", contains: "YAML")
    }

    func testBase24BrightANSIAndBase16Fallback() throws {
        let fallback = try Base16ThemeImporter.parse(yaml: "scheme: Fallback\n" + palette())
        XCTAssertEqual(fallback.ansiColors.map(\.hex), ["000000", "080808", "0B0B0B", "0A0A0A", "0D0D0D", "0E0E0E", "0C0C0C", "050505", "030303", "080808", "0B0B0B", "0A0A0A", "0D0D0D", "0E0E0E", "0C0C0C", "070707"])
        let base24 = try Base16ThemeImporter.parse(yaml: "scheme: Base24\n" + palette() + "base12: 121212\nbase13: 131313\nbase14: 141414\nbase15: 151515\nbase16: 161616\nbase17: 171717\n")
        XCTAssertEqual(Array(base24.ansiColors[9...14]).map(\.hex), ["121212", "141414", "131313", "161616", "171717", "151515"])
    }

    func testEveryLexerCategoryUsesSpecifiedBase16Role() throws {
        let theme = try Base16ThemeImporter.parse(yaml: "scheme: Roles\n" + palette())
        let expected: [(SyntaxTokenKind, String)] = [
            (.keyword, "0E0E0E"), (.operator, "050505"), (.tag, "080808"), (.string, "0B0B0B"), (.comment, "030303"),
            (.number, "090909"), (.type, "0A0A0A"), (.function, "0D0D0D"), (.property, "080808"), (.attribute, "0A0A0A")
        ]
        for (kind, hex) in expected { XCTAssertEqual(theme.tokenColor(for: kind).hex, hex, "Unexpected \(kind)") }
    }

    func testBlackOnWhiteContrastIsTwentyOneToOne() throws {
        let yaml = "scheme: Contrast\n" + palette()
            .replacingOccurrences(of: "base00: 000000", with: "base00: FFFFFF")
            .replacingOccurrences(of: "base05: 050505", with: "base05: 000000")
        XCTAssertEqual(try Base16ThemeImporter.parse(yaml: yaml).contrastRatio, 21, accuracy: 0.000_001)
    }

    func testBuiltinsPreserveTheirTerminalANSIAndRepresentativeRoles() {
        XCTAssertEqual(EditorTheme.dracula.background.hex, "282A36")
        XCTAssertEqual(EditorTheme.dracula.tokenColor(for: .keyword).hex, "FF79C6")
        XCTAssertEqual(EditorTheme.dracula.ansiColors.map(\.hex), ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2", "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"])
        XCTAssertEqual(EditorTheme.alucard.background.hex, "FFFBEB")
        XCTAssertEqual(EditorTheme.alucard.tokenColor(for: .keyword).hex, "A3144D")
        XCTAssertEqual(EditorTheme.alucard.ansiColors.map(\.hex), ["1F1F1F", "B3261E", "14710A", "846E15", "644AC9", "A3144D", "036A96", "FFFBEB", "6C664B", "D34038", "258C1B", "A88916", "7958DC", "C33A70", "087FAF", "FFFFFF"])
    }

    func testInvalidImportWritesNothing() throws {
        try withStore { store, root, _ in
            XCTAssertThrowsError(try store.importTheme(yaml: "scheme: Bad\nbase00: GG0000", sourceName: "bad.yaml"))
            XCTAssertEqual(store.themes, EditorTheme.builtins)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("FS Code/Themes").path))
        }
    }

    func testDuplicateRequiresReplacementAndReplacementPreservesSelectionID() throws {
        try withStore { store, root, defaults in
            let first = try store.importTheme(yaml: "scheme: Personal\n" + palette(), sourceName: "personal.yaml")
            store.setSelectedThemeID(first.id, for: .light)
            let updated = "scheme: Personal\n" + palette().replacingOccurrences(of: "base00: 000000", with: "base00: ABCDEF")
            XCTAssertThrowsError(try store.importTheme(yaml: updated, sourceName: "again.yaml"))
            let expectation = XCTNSNotificationExpectation(name: .editorThemeDidChange, object: store)
            let replacement = try store.importTheme(yaml: updated, sourceName: "again.yaml", replaceExisting: true)
            wait(for: [expectation], timeout: 0)
            XCTAssertEqual(replacement.id, first.id)
            XCTAssertEqual(store.selectedThemeID(for: .light), first.id)
            XCTAssertEqual(store.activeTheme(forDarkAppearance: false).background.hex, "ABCDEF")
            let relaunched = EditorThemeStore(applicationSupportURL: root, defaults: defaults)
            XCTAssertEqual(relaunched.selectedThemeID(for: .light), first.id)
            XCTAssertEqual(relaunched.activeTheme(forDarkAppearance: false).background.hex, "ABCDEF")
        }
    }

    func testMissingSelectedThemeNamesItOnceAndPersistsFallback() throws {
        try withStore { store, root, defaults in
            let imported = try store.importTheme(yaml: "scheme: Vanished\nvariant: dark\n" + palette(), sourceName: "vanished.yaml")
            store.setSelectedThemeID(imported.id, for: .dark)
            try FileManager.default.removeItem(at: root.appendingPathComponent("FS Code/Themes/\(imported.id).yaml"))
            let firstRelaunch = EditorThemeStore(applicationSupportURL: root, defaults: defaults)
            XCTAssertEqual(firstRelaunch.activeTheme(forDarkAppearance: true).id, EditorTheme.dracula.id)
            XCTAssertTrue(try XCTUnwrap(firstRelaunch.consumeMissingSelectionNotice()).contains("Vanished"))
            XCTAssertNil(firstRelaunch.consumeMissingSelectionNotice())
            XCTAssertNil(EditorThemeStore(applicationSupportURL: root, defaults: defaults).consumeMissingSelectionNotice())
        }
    }

    private func palette(indent: String = "", quotedHash: Bool = false, mixedCase: Bool = false) -> String {
        (0...15).map { value in
            var key = String(format: "base%02X", value)
            if mixedCase && value.isMultiple(of: 2) { key = key.lowercased() }
            let color = String(format: "%02X%02X%02X", value, value, value)
            return "\(indent)\(key): \(quotedHash ? "\"#\(color)\"" : color)"
        }.joined(separator: "\n") + "\n"
    }

    private func assertParseError(_ yaml: String, contains expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Base16ThemeImporter.parse(yaml: yaml), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.localizedCaseInsensitiveContains(expected), "\($0.localizedDescription)", file: file, line: line)
        }
    }

    private func withStore(_ body: (EditorThemeStore, URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "EditorThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try body(EditorThemeStore(applicationSupportURL: root, defaults: defaults), root, defaults)
    }
}
