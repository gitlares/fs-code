import Foundation

public enum SyntaxTokenKind: Sendable, Equatable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case property
    case tag
    case attribute
    case `operator`
}

public struct SyntaxToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A bounded, cancellation-aware lexical tokenizer for editor colouring.
/// It intentionally does not attempt AST or semantic analysis; Tree-sitter or
/// language services can be layered on later if the editor needs them.
public enum SyntaxTokenizer {
    public static func tokenize(_ text: String, language: SourceLanguage) -> [SyntaxToken] {
        guard language != .plainText, !text.isEmpty else { return [] }
        var scanner = Scanner(text, language: language)
        return scanner.scan()
    }
}

private struct Scanner {
    private let scalars: [Unicode.Scalar]
    private let language: SourceLanguage
    private var index = 0
    private var utf16Offset = 0
    private var tokens: [SyntaxToken] = []

    init(_ text: String, language: SourceLanguage) {
        self.scalars = Array(text.unicodeScalars)
        self.language = language
        self.tokens.reserveCapacity(min(1_024, max(8, text.utf16.count / 12)))
    }

    mutating func scan() -> [SyntaxToken] {
        while index < scalars.count {
            if index & 0x3FF == 0, Task.isCancelled { return tokens }
            if isMarkup {
                scanMarkup()
            } else {
                scanCode()
            }
        }
        return tokens
    }

    private var isMarkup: Bool { language == .html || language == .xml || language == .svg || language == .plist }
    private var isJSON: Bool { language == .json }
    private var isCSS: Bool { language == .css }
    private var allowsSingleQuotedStrings: Bool { !isJSON }
    private var supportsBlockComments: Bool { [.swift, .javascript, .jsx, .typescript, .tsx, .rust, .css].contains(language) }
    private var supportsSlashComments: Bool { [.swift, .javascript, .jsx, .typescript, .tsx, .rust].contains(language) }
    private var supportsTemplateStrings: Bool { [.javascript, .jsx, .typescript, .tsx].contains(language) }
    private var lineComment: Unicode.Scalar? {
        switch language {
        case .python, .shell: return "#"
        default: return nil
        }
    }

    private mutating func scanCode() {
        if supportsSlashComments && matches("//") {
            consumeComment(until: "\n")
        } else if let lineComment, current == lineComment {
            consumeComment(until: "\n")
        } else if supportsBlockComments && matches("/*") {
            consumeDelimited(kind: .comment, openerLength: 2, closer: "*/", allowsNewline: true)
        } else if (language == .python || language == .swift) && matches("\"\"\"") {
            consumeDelimited(kind: .string, openerLength: 3, closer: String(current!), allowsNewline: true, repeatedCloser: 3)
        } else if language == .python && matches("'''") {
            consumeDelimited(kind: .string, openerLength: 3, closer: String(current!), allowsNewline: true, repeatedCloser: 3)
        } else if supportsTemplateStrings && current == "`" {
            consumeQuotedString(quote: "`", allowsNewline: true)
        } else if let scalar = current, scalar == "\"" || (scalar == "'" && allowsSingleQuotedStrings && (language != .rust || isRustCharacterLiteral())) {
            consumeQuotedString(quote: scalar, allowsNewline: false)
        } else if let scalar = current, isASCIIIdentifierStart(scalar) {
            consumeIdentifier()
        } else if let scalar = current, isDigit(scalar) || (scalar == "." && isDigit(peek(1))) || (isCSS && scalar == "#" && isHexDigit(peek(1))) {
            consumeNumber()
        } else if let scalar = current, isOperator(scalar) {
            let start = mark()
            advance()
            emit(from: start, kind: .operator)
        } else {
            advance()
        }
    }

    private mutating func scanMarkup() {
        if matches("<!--") {
            consumeDelimited(kind: .comment, openerLength: 4, closer: "-->", allowsNewline: true)
            return
        }
        guard current == "<" else { advance(); return }
        advance()
        if current == "/" || current == "?" || current == "!" { advance() }
        if let scalar = current, isASCIIIdentifierStart(scalar) {
            let tagStart = mark()
            consumePlainIdentifier(kind: .tag, start: tagStart)
        }
        while index < scalars.count, current != ">" {
            if index & 0x3FF == 0, Task.isCancelled { return }
            if let scalar = current, scalar == "\"" || scalar == "'" {
                consumeQuotedString(quote: scalar, allowsNewline: false)
            } else if let scalar = current, isASCIIIdentifierStart(scalar) {
                let start = mark()
                consumePlainIdentifier(kind: .attribute, start: start)
            } else {
                advance()
            }
        }
        if current == ">" { advance() }
    }

    private mutating func consumeComment(until delimiter: Unicode.Scalar) {
        let start = mark()
        while let scalar = current, scalar != delimiter {
            if index & 0x3FF == 0, Task.isCancelled { return }
            advance()
        }
        emit(from: start, kind: .comment)
    }

    private mutating func consumeDelimited(kind: SyntaxTokenKind, openerLength: Int, closer: String, allowsNewline: Bool, repeatedCloser: Int = 1) {
        let start = mark()
        for _ in 0..<openerLength { advance() }
        while index < scalars.count {
            if index & 0x3FF == 0, Task.isCancelled { return }
            if !allowsNewline, current == "\n" { break }
            if matches(closer, count: repeatedCloser) {
                for _ in 0..<(closer.unicodeScalars.count * repeatedCloser) { advance() }
                break
            }
            advance()
        }
        emit(from: start, kind: kind)
    }

    private mutating func consumeQuotedString(quote: Unicode.Scalar, allowsNewline: Bool) {
        // A lone Rust lifetime (for example `'a`) was filtered before this call.
        // An incomplete literal remains a string through its line so an embedded
        // comment marker cannot be misclassified as code.
        let start = mark()
        advance()
        while let scalar = current {
            if index & 0x3FF == 0, Task.isCancelled { return }
            if !allowsNewline && (scalar == "\n" || scalar == "\r") { break }
            if scalar == "\\" { advance(); if current != nil { advance() }; continue }
            advance()
            if scalar == quote { break }
        }
        emit(from: start, kind: stringKind(afterQuotedRangeStartingAt: start))
    }

    private func stringKind(afterQuotedRangeStartingAt start: (index: Int, offset: Int)) -> SyntaxTokenKind {
        guard isJSON else { return .string }
        var lookahead = index
        while lookahead < scalars.count, isWhitespace(scalars[lookahead]) {
            if lookahead & 0x3FF == 0, Task.isCancelled { return .string }
            lookahead += 1
        }
        return lookahead < scalars.count && scalars[lookahead] == ":" ? .property : .string
    }

    private func isRustCharacterLiteral() -> Bool {
        var cursor = index + 1
        guard cursor < scalars.count else { return false }
        if scalars[cursor] == "\\" { cursor += 2 } else { cursor += 1 }
        return cursor < scalars.count && scalars[cursor] == "'"
    }

    private mutating func consumeIdentifier() {
        let start = mark()
        while let scalar = current, isASCIIIdentifierContinue(scalar) {
            if index & 0x3FF == 0, Task.isCancelled { return }
            advance()
        }
        let word = asciiString(from: start.index, to: index)
        let kind: SyntaxTokenKind?
        if LanguageLexicon.keywords(for: language).contains(word) || LanguageLexicon.literals.contains(word) {
            kind = .keyword
        } else if isCSS && nextNonWhitespaceIsColon() {
            kind = .property
        } else if nextNonWhitespaceIs("(") {
            kind = .function
        } else if word.first?.isUppercase == true {
            kind = .type
        } else {
            kind = nil
        }
        if let kind { emit(from: start, kind: kind) }
    }

    private mutating func consumePlainIdentifier(kind: SyntaxTokenKind, start: (index: Int, offset: Int)) {
        while let scalar = current, isASCIIIdentifierContinue(scalar) {
            if index & 0x3FF == 0, Task.isCancelled { return }
            advance()
        }
        emit(from: start, kind: kind)
    }

    private mutating func consumeNumber() {
        let start = mark()
        if current == "#" {
            advance()
            while isHexDigit(current) { if index & 0x3FF == 0, Task.isCancelled { return }; advance() }
        } else if current == "0", peek(1) == "x" || peek(1) == "X" {
            advance(); advance()
            while isHexDigit(current) || current == "_" { if index & 0x3FF == 0, Task.isCancelled { return }; advance() }
        } else {
            while isDigit(current) || current == "_" { if index & 0x3FF == 0, Task.isCancelled { return }; advance() }
            if current == ".", isDigit(peek(1)) {
                advance()
                while isDigit(current) || current == "_" { if index & 0x3FF == 0, Task.isCancelled { return }; advance() }
            }
            if current == "e" || current == "E" {
                let exponentStart = mark()
                advance()
                if current == "+" || current == "-" { advance() }
                if isDigit(current) {
                    while isDigit(current) || current == "_" { if index & 0x3FF == 0, Task.isCancelled { return }; advance() }
                } else {
                    index = exponentStart.index
                    utf16Offset = exponentStart.offset
                }
            }
        }
        emit(from: start, kind: .number)
    }
    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }
    private func peek(_ distance: Int) -> Unicode.Scalar? { let position = index + distance; return position < scalars.count ? scalars[position] : nil }
    private func mark() -> (index: Int, offset: Int) { (index, utf16Offset) }
    private mutating func advance() { guard let scalar = current else { return }; utf16Offset += scalar.value > 0xFFFF ? 2 : 1; index += 1 }
    private mutating func emit(from start: (index: Int, offset: Int), kind: SyntaxTokenKind) { guard utf16Offset > start.offset else { return }; tokens.append(SyntaxToken(range: NSRange(location: start.offset, length: utf16Offset - start.offset), kind: kind)) }
    private func matches(_ text: String, count: Int = 1) -> Bool { let target = Array(text.unicodeScalars); let expected = target.count * count; guard index + expected <= scalars.count else { return false }; return (0..<expected).allSatisfy { scalars[index + $0] == target[$0 % target.count] } }
    private func asciiString(from start: Int, to end: Int) -> String { String(bytes: scalars[start..<end].map { UInt8($0.value) }, encoding: .utf8) ?? "" }
    private func nextNonWhitespaceIs(_ scalar: Unicode.Scalar) -> Bool {
        var cursor = index
        while cursor < scalars.count, isWhitespace(scalars[cursor]) {
            if cursor & 0x3FF == 0, Task.isCancelled { return false }
            cursor += 1
        }
        return cursor < scalars.count && scalars[cursor] == scalar
    }
    private func nextNonWhitespaceIsColon() -> Bool { nextNonWhitespaceIs(":") }
}

private enum LanguageLexicon {
    static let literals: Set<String> = ["true", "false", "null", "nil", "none", "True", "False", "None"]

    static func keywords(for language: SourceLanguage) -> Set<String> {
        switch language {
        case .swift: swiftKeywords
        case .python: pythonKeywords
        case .javascript, .jsx, .typescript, .tsx: javascriptKeywords
        case .rust: rustKeywords
        case .shell: shellKeywords
        case .css: cssKeywords
        default: []
        }
    }

    private static let swiftKeywords: Set<String> = ["actor", "async", "await", "break", "case", "catch", "class", "continue", "defer", "do", "else", "enum", "extension", "fallthrough", "for", "func", "guard", "if", "import", "in", "init", "let", "protocol", "public", "private", "return", "static", "struct", "switch", "throw", "throws", "try", "var", "where", "while"]
    private static let pythonKeywords: Set<String> = ["and", "as", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
    private static let javascriptKeywords: Set<String> = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "for", "from", "function", "if", "import", "in", "interface", "let", "new", "of", "return", "switch", "throw", "try", "type", "var", "while", "yield"]
    private static let rustKeywords: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "struct", "trait", "use", "where", "while"]
    private static let shellKeywords: Set<String> = ["case", "do", "done", "echo", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "then", "while"]
    private static let cssKeywords: Set<String> = ["important", "inherit", "initial", "none", "unset"]
}

private func isASCIIIdentifierStart(_ scalar: Unicode.Scalar) -> Bool { scalar == "_" || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) }
private func isASCIIIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool { isASCIIIdentifierStart(scalar) || isDigit(scalar) }
private func isDigit(_ scalar: Unicode.Scalar?) -> Bool { guard let scalar else { return false }; return scalar.value >= 48 && scalar.value <= 57 }
private func isHexDigit(_ scalar: Unicode.Scalar?) -> Bool { guard let scalar else { return false }; return isDigit(scalar) || (scalar.value >= 65 && scalar.value <= 70) || (scalar.value >= 97 && scalar.value <= 102) }
private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" }
private func isOperator(_ scalar: Unicode.Scalar) -> Bool { "+-*/%=!<>&|^~?:".unicodeScalars.contains(scalar) }
