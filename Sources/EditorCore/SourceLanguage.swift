import Foundation

/// The supported lexical language modes. This deliberately describes editor
/// highlighting only; it is not a parser or a semantic language service.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case plainText
    case swift
    case python
    case javascript
    case jsx
    case typescript
    case tsx
    case json
    case html
    case css
    case rust
    case shell
    case xml
    case svg
    case plist

    public var displayName: String {
        switch self {
        case .plainText: "Plain Text"
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .jsx: "JSX"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .json: "JSON"
        case .html: "HTML"
        case .css: "CSS"
        case .rust: "Rust"
        case .shell: "Shell"
        case .xml: "XML"
        case .svg: "SVG"
        case .plist: "Property List"
        }
    }

    public static func detect(filename: String?, firstLine: String = "") -> Self {
        if let filename {
            let basename = URL(fileURLWithPath: filename).lastPathComponent.lowercased()
            if let language = filenames[basename] { return language }

            let pathExtension = URL(fileURLWithPath: basename).pathExtension.lowercased()
            if let language = extensions[pathExtension] { return language }
        }
        return language(forShebang: firstLine) ?? .plainText
    }

    public static func detect(url: URL?, firstLine: String = "") -> Self {
        detect(filename: url?.lastPathComponent, firstLine: firstLine)
    }

    private static func language(forShebang firstLine: String) -> Self? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let words = firstLine.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "/" }).map(String.init)
        if words.contains(where: { $0.hasPrefix("python") }) { return .python }
        if words.contains("node") || words.contains("nodejs") { return .javascript }
        if words.contains(where: { ["bash", "zsh", "sh", "dash", "fish", "ksh"].contains($0) }) { return .shell }
        return nil
    }

    private static let filenames: [String: Self] = [
        ".bashrc": .shell, ".bash_profile": .shell, ".profile": .shell,
        ".zprofile": .shell, ".zshrc": .shell,
        "package.json": .json, "tsconfig.json": .json,
        "info.plist": .plist
    ]

    private static let extensions: [String: Self] = [
        "swift": .swift,
        "py": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript,
        "jsx": .jsx,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "json": .json, "jsonc": .json,
        "html": .html, "htm": .html,
        "css": .css,
        "rs": .rust,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "xml": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml,
        "svg": .svg,
        "plist": .plist
    ]
}
