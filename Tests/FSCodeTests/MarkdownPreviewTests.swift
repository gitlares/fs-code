import AppKit
import XCTest
@testable import FSCode

@MainActor final class MarkdownPreviewTests: XCTestCase {
    private func textView(in preview: MarkdownPreviewView) throws -> NSTextView {
        try XCTUnwrap(preview.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first)
    }

    private func waitForRender(_ textView: NSTextView) async throws {
        for _ in 0..<100 where textView.string == "Rendering Markdown…" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(textView.string, "Rendering Markdown…")
    }

    func testFoundationMarkdownRendersHeadingListInlineAndFencedCode() async throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let view = try textView(in: preview)
        preview.showMarkdown(source: "# Heading\n\nFirst paragraph.\n\n- one\n- two\n\n1. alpha\n2. beta\n\n> quoted\n\nUse **bold**, *italic*, ***both*** and `value`.\n\n```swift\nlet answer = 42\n```")
        try await waitForRender(view)
        XCTAssertEqual(view.string, "Heading\nFirst paragraph.\n• one\n• two\n1. alpha\n2. beta\nquoted\nUse bold, italic, both and value.\nlet answer = 42\n")
        let headingRange = (view.string as NSString).range(of: "Heading")
        let headingFont = view.attributedString().attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, NSFont.systemFontSize)
        let boldRange = (view.string as NSString).range(of: "bold")
        let italicRange = (view.string as NSString).range(of: "italic")
        let bothRange = (view.string as NSString).range(of: "both")
        XCTAssertTrue((view.attributedString().attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue((view.attributedString().attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let bothTraits = (view.attributedString().attribute(.font, at: bothRange.location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        XCTAssertTrue(bothTraits?.contains(.bold) == true)
        XCTAssertTrue(bothTraits?.contains(.italic) == true)
        let codeRange = (view.string as NSString).range(of: "let answer = 42")
        let codeFont = view.attributedString().attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(codeFont?.fontName, NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular).fontName)
    }

    func testLaterMarkdownRequestSupersedesEarlierRequest() async throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let view = try textView(in: preview)
        preview.showMarkdown(source: "# Older")
        preview.showMarkdown(source: "# Newest")
        try await waitForRender(view)
        XCTAssertTrue(view.string.contains("Newest"))
        XCTAssertFalse(view.string.contains("Older"))
    }

    func testSharedRendererProducesSelectableAssistantMarkdown() throws {
        let rendered = try XCTUnwrap(
            MarkdownPreviewView.renderedMarkdown("## Answer\n\nUse **bold** and `code`.\n\n- first\n- second")
        )
        XCTAssertEqual(rendered.string, "Answer\nUse bold and code.\n• first\n• second\n")
        let headingRange = (rendered.string as NSString).range(of: "Answer")
        let headingFont = rendered.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, NSFont.systemFontSize)
        let codeRange = (rendered.string as NSString).range(of: "code")
        let codeFont = rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(codeFont?.fontName, NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular).fontName)
    }

    func testRendererLinksOnlySafeURLsAndStylesPathsInCode() throws {
        let rendered = try XCTUnwrap(MarkdownPreviewView.renderedMarkdown(
            "[safe](https://example.com) [unsafe](file:///tmp/nope) https://openai.com mailto:hi@example.com `Sources/FSCode/App.swift`\n\n```text\nhttps://example.org /tmp/log.txt\n```"
        ))
        let string = rendered.string as NSString
        for (visibleText, scheme) in [("safe", "https"), ("https://openai.com", "https"), ("mailto:hi@example.com", "mailto"), ("https://example.org", "https")] {
            let range = string.range(of: visibleText)
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertEqual((rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.scheme, scheme)
            XCTAssertEqual(rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, NSColor.linkColor)
        }
        let unsafeRange = string.range(of: "unsafe")
        XCTAssertNil(rendered.attribute(.link, at: unsafeRange.location, effectiveRange: nil))
        let pathRange = string.range(of: "Sources/FSCode/App.swift")
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: pathRange.location, effectiveRange: nil) as? NSColor, NSColor.systemIndigo)
        let fencedPathRange = string.range(of: "/tmp/log.txt")
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: fencedPathRange.location, effectiveRange: nil) as? NSColor, NSColor.systemIndigo)
    }

    func testAssistantRenderingSeparatesTablesAndReplacesOpaqueCitationsOnly() throws {
        let source = "| Name | Value |\n| --- | --- |\n| One | Two |\n\nplain cite text\n\u{E200}cite\u{E202}turn2search0\u{E202}turn2search3\u{E201}"
        let assistant = try XCTUnwrap(MarkdownPreviewView.renderedMarkdown(source, presentation: .assistant))
        XCTAssertEqual(assistant.string, "Name  •  Value\nOne  •  Two\nplain cite text [Source unavailable]\n")
        XCTAssertFalse(assistant.string.contains("turn2search0"))
        XCTAssertTrue(assistant.string.contains("plain cite text"))

        let document = try XCTUnwrap(MarkdownPreviewView.renderedMarkdown(source))
        XCTAssertTrue(document.string.contains("turn2search0"))
    }

    func testTablesInsideFencedCodeRemainLiteral() throws {
        let source = "```text\n| Name | Value |\n| --- | --- |\n| One | Two |\n```\n\n| Name | Value |\n| --- | --- |\n| One | Two |"
        let rendered = try XCTUnwrap(MarkdownPreviewView.renderedMarkdown(source))
        XCTAssertTrue(rendered.string.contains("| Name | Value |"))
        XCTAssertTrue(rendered.string.contains("Name  •  Value"))
    }
}
