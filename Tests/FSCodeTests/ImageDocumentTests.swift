import AppKit
import XCTest
@testable import FSCode

@MainActor final class ImageDocumentTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    func testSVGPreviewUsesDraftAndKeepsUndoAndSaveState() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.svg")
        let original = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\" fill=\"red\"/></svg>"
        try Data(original.utf8).write(to: url)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }
        editor.layoutSubtreeIfNeeded()
        await editor.open(url)
        let svg = try XCTUnwrap(descendants(editor, of: SVGDocumentView.self).first)
        XCTAssertTrue(svg.isShowingPreview)
        svg.showCode()
        let text = try XCTUnwrap(descendants(svg, of: CodeTextView.self).first)
        let draft = original.replacingOccurrences(of: "red", with: "blue")
        text.insertText(draft, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        XCTAssertTrue(editor.hasUnsavedChanges)
        let undo = text.undoManager
        svg.showPreview()
        XCTAssertTrue(svg.isShowingPreview)
        XCTAssertEqual(text.string, draft)
        XCTAssertTrue(text.undoManager === undo)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        await editor.saveActive()
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), draft)
        svg.showCode()
        text.undoManager?.undo()
        XCTAssertEqual(text.string, original)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    func testRasterTabsNeverBecomeEditableAndClosingRestoresTextTab() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("hello.txt")
        try Data("Hello".utf8).write(to: textURL)
        let imageURL = folder.appendingPathComponent("pixel.png")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3_000, pixelsHigh: 1_000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try bytes.write(to: imageURL)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }
        editor.layoutSubtreeIfNeeded()
        await editor.open(textURL)
        await editor.open(imageURL)
        let preview = try XCTUnwrap(descendants(editor, of: ImagePreviewView.self).first)
        let imageView = try XCTUnwrap(descendants(preview, of: NSImageView.self).first)
        for _ in 0..<100 where imageView.image == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        editor.layoutSubtreeIfNeeded()
        let rendered = try XCTUnwrap(imageView.image)
        XCTAssertLessThanOrEqual(rendered.size.width, 2_048)
        XCTAssertGreaterThan(preview.bounds.width, 0)
        XCTAssertLessThanOrEqual(preview.frame.width, editor.bounds.width)
        XCTAssertLessThanOrEqual(imageView.frame.maxX, preview.bounds.width)
        XCTAssertLessThanOrEqual(imageView.frame.maxY, preview.bounds.height)
        XCTAssertEqual(editor.activeFileURL, imageURL.resolvingSymlinksInPath())
        XCTAssertFalse(editor.canSave)
        XCTAssertFalse(editor.canFind)
        await editor.saveActive()
        XCTAssertEqual(try Data(contentsOf: imageURL), bytes)
        await editor.open(imageURL)
        let closedImage = await editor.closeActive()
        XCTAssertTrue(closedImage)
        XCTAssertEqual(editor.activeFileURL, textURL.resolvingSymlinksInPath())
        XCTAssertTrue(editor.canSave)
        let closedText = await editor.closeActive()
        XCTAssertTrue(closedText)
        XCTAssertFalse(editor.hasOpenFiles)
    }

    func testDocumentModeSelectorFollowsTheActiveTab() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("notes.txt")
        let svgURL = folder.appendingPathComponent("art.svg")
        try Data("Notes".utf8).write(to: textURL)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: svgURL)

        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }

        let selector = try XCTUnwrap(descendants(editor, of: NSSegmentedControl.self).first {
            $0.accessibilityLabel() == "Document view mode"
        })
        await editor.open(textURL)
        XCTAssertTrue(selector.isHidden)
        await editor.open(svgURL)
        XCTAssertFalse(selector.isHidden)
        XCTAssertEqual(selector.selectedSegment, 0)
        await editor.open(textURL)
        XCTAssertTrue(selector.isHidden)
    }

    func testInvalidOrExternalSVGDoesNotKeepStaleImage() async throws {
        _ = NSApplication.shared
        let preview = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let good = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>"
        let image = try XCTUnwrap(descendants(preview, of: NSImageView.self).first)
        preview.showSVG(source: good)
        XCTAssertNotNil(image.image)
        preview.showSVG(source: "<svg><broken>")
        XCTAssertNil(image.image)
        preview.showSVG(source: good)
        XCTAssertNotNil(image.image)
        preview.showSVG(source: "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"https://example.invalid/test.png\"/></svg>")
        XCTAssertNil(image.image)
        preview.showSVG(source: good)
        XCTAssertNotNil(image.image)
        preview.showSVG(source: "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect fill=\"u\\72l(https://example.invalid/test.png)\"/></svg>")
        XCTAssertNil(image.image)
        preview.showSVG(source: good)
        XCTAssertNotNil(image.image)
    }

    func testMarkdownPreviewUsesDraftAndKeepsUndoAndSaveState() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.md")
        let original = "# Original\n\n- first"
        try Data(original.utf8).write(to: url)
        let editor = TextEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = editor
        defer { host.close() }

        await editor.open(url)
        let preview = try XCTUnwrap(descendants(editor, of: DocumentPreviewView.self).first)
        XCTAssertFalse(preview.isShowingPreview)
        XCTAssertFalse(preview.subviews[0].isHidden, "Markdown starts in editable source mode")
        XCTAssertTrue(preview.subviews[1].isHidden, "The rendered view is hidden until Preview is selected")
        let text = try XCTUnwrap(descendants(preview, of: CodeTextView.self).first)
        let draft = "# Draft\n\n- first\n- second"
        text.insertText(draft, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        let undo = text.undoManager
        preview.showPreview()
        XCTAssertTrue(preview.isShowingPreview)
        XCTAssertEqual(text.string, draft)
        XCTAssertTrue(text.undoManager === undo)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        await editor.saveActive()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), draft)
    }

}
