import XCTest
@testable import EditorCore

final class LineIndexTests: XCTestCase {
    func testEmptyTextHasOneLine() {
        let index = LineIndex()

        XCTAssertEqual(index.lineStarts, [0])
        XCTAssertEqual(index.lineCount, 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 0), 1)
    }

    func testRecognizesLFCRAndCRLFAsLogicalLineEndings() {
        let index = LineIndex(text: "one\r\ntwo\nthree\rfour")

        XCTAssertEqual(index.lineStarts, [0, 5, 9, 15])
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 0), 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 5), 2)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 9), 3)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 15), 4)
    }

    func testRecognizesUnicodeLineSeparators() {
        let index = LineIndex(text: "one\u{0085}two\u{2028}three\u{2029}four")

        XCTAssertEqual(index.lineStarts, [0, 4, 8, 14])
    }

    func testKeepsUTF16OffsetsForUnicodeText() {
        let index = LineIndex(text: "😀\nCafé\r\n終")

        // 😀 is two UTF-16 code units and the combining accent is one more.
        XCTAssertEqual(index.lineStarts, [0, 3, 10])
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 2), 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 3), 2)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 10), 3)
    }

    func testTrailingNewlineCreatesAnEmptyFinalLine() {
        let index = LineIndex(text: "last\n")

        XCTAssertEqual(index.lineStarts, [0, 5])
        XCTAssertEqual(index.lineCount, 2)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 5), 2)
    }

    func testUpdateRebuildsTheIndexAndClampsNegativeOffsets() {
        var index = LineIndex(text: "one")
        index.update(for: "one\rtwo")

        XCTAssertEqual(index.lineStarts, [0, 4])
        XCTAssertEqual(index.lineNumber(atUTF16Offset: -1), 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 999), 2)
        XCTAssertEqual(index.position(atUTF16Offset: 4).line, 2)
        XCTAssertEqual(index.position(atUTF16Offset: 4).column, 1)
        XCTAssertEqual(index.position(atUTF16Offset: 999).column, 4)
    }
}
