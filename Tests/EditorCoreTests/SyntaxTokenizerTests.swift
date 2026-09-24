import Foundation
import XCTest
@testable import EditorCore

final class SyntaxTokenizerTests: XCTestCase {
    func testDetectionPrefersFilenameThenExtensionThenShebang() {
        XCTAssertEqual(SourceLanguage.detect(filename: ".zshrc", firstLine: "#!/usr/bin/env python3"), .shell)
        XCTAssertEqual(SourceLanguage.detect(filename: "View.TSX"), .tsx)
        XCTAssertEqual(SourceLanguage.detect(filename: nil, firstLine: "#!/usr/bin/env python3"), .python)
        XCTAssertEqual(SourceLanguage.detect(filename: "README", firstLine: "#!/bin/zsh"), .shell)
        XCTAssertEqual(SourceLanguage.detect(filename: "notes.unknown"), .plainText)
        XCTAssertEqual(SourceLanguage.detect(filename: "Dockerfile"), .plainText)
        XCTAssertEqual(SourceLanguage.detect(filename: "Makefile"), .plainText)
    }

    func testStringsAndCommentsDoNotLeakIntoCodeTokens() {
        let tokens = SyntaxTokenizer.tokenize("let text = \"// not a comment\" // actual", language: .swift)
        XCTAssertTrue(tokens.contains { $0.kind == .string })
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 1)
    }

    func testUnclosedStringStaysAStringThroughItsLine() {
        let tokens = SyntaxTokenizer.tokenize("let text = \"// still text\nlet next = 1", language: .swift)
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 0)
        XCTAssertTrue(tokens.contains { $0.kind == .string })
    }

    func testNumbersDoNotAbsorbOperatorsOrFollowingIdentifiers() {
        let source = "let value = 1+foo; let hex = 0xFF; let ratio = 1.5e-2"
        let tokens = SyntaxTokenizer.tokenize(source, language: .swift)
        let numbers = tokens.filter { $0.kind == .number }.map { (source as NSString).substring(with: $0.range) }
        XCTAssertEqual(numbers, ["1", "0xFF", "1.5e-2"])
        XCTAssertTrue(tokens.contains { $0.kind == .operator && (source as NSString).substring(with: $0.range) == "+" })
    }

    func testTemplateAndMultilineStringsAreSingleStringTokens() {
        let template = SyntaxTokenizer.tokenize("const message = `hello ${name}`", language: .typescript)
        XCTAssertEqual(template.filter { $0.kind == .string }.count, 1)
        let multiline = SyntaxTokenizer.tokenize("let message = \"\"\"hello\\nworld\"\"\"", language: .swift)
        XCTAssertEqual(multiline.filter { $0.kind == .string }.count, 1)
    }

    func testJSONPropertiesAndCSSHexValues() {
        let json = SyntaxTokenizer.tokenize("{\"name\": \"Ada\", \"ok\": true}", language: .json)
        XCTAssertEqual(json.filter { $0.kind == .property }.count, 2)
        XCTAssertTrue(json.contains { $0.kind == .keyword })
        let css = SyntaxTokenizer.tokenize(".card { color: #ff00aa; }", language: .css)
        XCTAssertTrue(css.contains { $0.kind == .property })
        XCTAssertTrue(css.contains { $0.kind == .number })
        XCTAssertFalse(css.contains { $0.kind == .comment })
    }

    func testMarkupHandlesCommentsTagsAttributesAndEmojiUTF16Ranges() {
        let source = "🙂<!-- note --><svg viewBox=\"0 0 1 1\"></svg>"
        let tokens = SyntaxTokenizer.tokenize(source, language: .svg)
        XCTAssertTrue(tokens.contains { $0.kind == .comment })
        XCTAssertEqual(tokens.filter { $0.kind == .tag }.count, 2)
        let attribute = try! XCTUnwrap(tokens.first { $0.kind == .attribute })
        XCTAssertEqual(attribute.range.location, 20) // 🙂 is two UTF-16 code units.
    }

    func testRustLifetimeDoesNotBecomeAnUnboundedString() {
        let tokens = SyntaxTokenizer.tokenize("fn borrow<'a>(value: &'a str) {}", language: .rust)
        XCTAssertTrue(tokens.contains { $0.kind == .keyword })
        XCTAssertFalse(tokens.contains { $0.kind == .string })
    }
}
