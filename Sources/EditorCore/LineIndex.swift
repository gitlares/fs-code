import Foundation

/// Maps UTF-16 character offsets to logical (unwrapped) line numbers.
///
/// AppKit's text APIs express character ranges as UTF-16 offsets, so this index
/// deliberately uses the same representation. A CRLF pair is one line ending.
public struct LineIndex: Sendable, Equatable {
    public private(set) var lineStarts: [Int]
    private var textUTF16Length: Int

    public init(text: String = "") {
        let index = Self.makeIndex(for: text)
        lineStarts = index.starts
        textUTF16Length = index.length
    }

    public mutating func update(for text: String) {
        let index = Self.makeIndex(for: text)
        lineStarts = index.starts
        textUTF16Length = index.length
    }

    /// Returns the one-based logical line containing `utf16Offset`.
    /// Offsets outside the document are clamped to its valid bounds.
    public func lineNumber(atUTF16Offset utf16Offset: Int) -> Int {
        position(atUTF16Offset: utf16Offset).line
    }

    /// Returns a one-based logical line and UTF-16 column for `utf16Offset`.
    /// The column follows AppKit's UTF-16 character-range convention, making it
    /// stable for the editor's selection and TextKit 2 layout APIs.
    public func position(atUTF16Offset utf16Offset: Int) -> (line: Int, column: Int) {
        let offset = min(max(0, utf16Offset), textUTF16Length)
        var lowerBound = 0
        var upperBound = lineStarts.count

        // Upper-bound binary search: locate the last line start <= offset.
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[midpoint] <= offset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        let lineIndex = lowerBound - 1
        return (lineIndex + 1, offset - lineStarts[lineIndex] + 1)
    }

    public var lineCount: Int { lineStarts.count }

    private static func makeIndex(for text: String) -> (starts: [Int], length: Int) {
        var starts = [0]
        var offset = 0
        var previousWasCR = false

        for codeUnit in text.utf16 {
            if previousWasCR {
                if codeUnit == 0x000A {
                    offset += 1
                    starts.append(offset)
                    previousWasCR = false
                    continue
                }
                starts.append(offset)
                previousWasCR = false
            }

            switch codeUnit {
            case 0x000D:
                offset += 1
                previousWasCR = true
            case 0x000A, 0x0085, 0x2028, 0x2029:
                offset += 1
                starts.append(offset)
            default:
                offset += 1
            }
        }
        if previousWasCR { starts.append(offset) }
        return (starts, offset)
    }
}
