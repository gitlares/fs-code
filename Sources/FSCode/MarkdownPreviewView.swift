import AppKit
import Foundation

/// A native, deliberately bounded Markdown reader.
///
/// The supported subset is Foundation's fully interpreted Markdown: headings,
/// paragraphs, emphasis, strong emphasis, inline and fenced code, ordered and
/// unordered lists, block quotes and links. Images remain their alt text and no
/// remote resource is fetched. Tables use Foundation's plain textual output in
/// this first native implementation.
/// HTML is never rendered or executed.
@MainActor
final class MarkdownPreviewView: NSView, NSTextViewDelegate {
    /// Rendering intent is deliberately limited to presentation. The original
    /// Markdown remains the caller's responsibility, which keeps chat cleanup
    /// from altering files opened in the editor.
    enum Presentation {
        case document
        case assistant
    }

    private static let maximumSourceBytes = 5 * 1024 * 1024
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private let scrollView = NSScrollView()
    private let textView = NSTextView(usingTextLayoutManager: true)
    private var renderTask: Task<Void, Never>?
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.delegate = self
        textView.setAccessibilityLabel("Markdown preview")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { renderTask?.cancel() }

    /// Renders the current editor buffer; a later request supersedes an older one.
    func showMarkdown(source: String) {
        generation &+= 1
        renderTask?.cancel()
        let requestGeneration = generation
        guard source.lengthOfBytes(using: .utf8) <= Self.maximumSourceBytes else {
            textView.string = "This Markdown document is larger than 5 MiB."
            textView.setAccessibilityValue("Markdown document is too large to preview")
            return
        }

        textView.string = "Rendering Markdown…"
        textView.setAccessibilityValue("Rendering Markdown")
        let renderSource = Self.normalizedSource(source, presentation: .document)
        renderTask = Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) {
                try? AttributedString(markdown: renderSource, options: .init(interpretedSyntax: .full))
            }.value
            guard !Task.isCancelled, let self, requestGeneration == self.generation else { return }
            guard let parsed else {
                self.textView.string = "This Markdown document could not be rendered."
                self.textView.setAccessibilityValue("Markdown rendering failed")
                return
            }
            self.textView.textStorage?.setAttributedString(Self.decorateTokens(in: Self.sanitizedLinks(in: Self.style(parsed))))
            self.textView.setAccessibilityValue("Markdown preview")
        }
    }

    /// Reuses the bounded native renderer for selectable assistant responses.
    /// Foundation leaves tables as plain text; it never evaluates HTML or fetches content.
    static func renderedMarkdown(_ source: String, presentation: Presentation = .document) -> NSAttributedString? {
        guard source.lengthOfBytes(using: .utf8) <= maximumSourceBytes,
              let parsed = try? AttributedString(markdown: normalizedSource(source, presentation: presentation), options: .init(interpretedSyntax: .full)) else {
            return nil
        }
        return decorateTokens(in: sanitizedLinks(in: style(parsed)))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, Self.isSafeLink(url) else { return true }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    /// Applies only URLs that can be safely opened by the native text view.
    /// It is shared by the editor preview and assistant transcript so tool output
    /// and fenced code receive the same conservative URL treatment.
    static func linkifySafeURLs(in source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            let url: URL?
            if let link = value as? URL {
                url = link
            } else if let text = value as? String {
                url = URL(string: text)
            } else {
                url = nil
            }
            guard let url, isSafeLink(url) else {
                result.removeAttribute(.link, range: range)
                return
            }
            applyLinkAppearance(to: result, range: range)
        }
        linkDetector?.enumerateMatches(in: result.string, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url, isSafeLink(url),
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { return }
            result.addAttribute(.link, value: url, range: match.range)
            applyLinkAppearance(to: result, range: match.range)
        }
        let mailto = try? NSRegularExpression(pattern: "(?i)mailto:[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}")
        mailto?.enumerateMatches(in: result.string, range: fullRange) { match, _, _ in
            guard let match,
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                  let url = URL(string: (result.string as NSString).substring(with: match.range)),
                  isSafeLink(url) else { return }
            result.addAttribute(.link, value: url, range: match.range)
            applyLinkAppearance(to: result, range: match.range)
        }
        return result
    }

    static func renderedToolText(_ source: String) -> NSAttributedString {
        decorateTokens(in: linkifySafeURLs(in: NSAttributedString(string: source)))
    }

    private static func sanitizedLinks(in source: NSAttributedString) -> NSAttributedString {
        linkifySafeURLs(in: source)
    }

    private static func applyLinkAppearance(to string: NSMutableAttributedString, range: NSRange) {
        string.addAttributes([
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], range: range)
    }

    private static func normalizedSource(_ source: String, presentation: Presentation) -> String {
        let chatCleaned: String
        switch presentation {
        case .document: chatCleaned = source
        case .assistant: chatCleaned = replacingOpaqueCitations(in: source)
        }
        return normalizedTables(in: chatCleaned)
    }

    /// Foundation's Markdown bridge can concatenate table cells. Convert only
    /// recognizable pipe tables to ordinary paragraphs with visible cell breaks.
    private static func normalizedTables(in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var fence: String?
        while index < lines.count {
            if let marker = fence {
                output.append(lines[index])
                if isFence(lines[index], marker: marker) { fence = nil }
                index += 1
                continue
            }
            if let marker = fenceMarker(in: lines[index]) {
                fence = marker
                output.append(lines[index])
                index += 1
                continue
            }
            guard index + 1 < lines.count,
                  !isIndentedCode(lines[index]),
                  isTableRow(lines[index]), isTableDivider(lines[index + 1]) else {
                output.append(lines[index])
                index += 1
                continue
            }
            output.append(tableParagraph(lines[index]))
            output.append("")
            index += 2
            while index < lines.count, !isIndentedCode(lines[index]), isTableRow(lines[index]) {
                output.append(tableParagraph(lines[index]))
                output.append("")
                index += 1
            }
        }
        return output.joined(separator: "\n")
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.trimmingCharacters(in: .whitespaces).filter { $0 == "|" }.count >= 2
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let cells = line.split(separator: "|", omittingEmptySubsequences: true)
        return !cells.isEmpty && cells.allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableParagraph(_ line: String) -> String {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.first == "|" { content.removeFirst() }
        if content.last == "|" { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "  •  ")
    }

    private static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
    }

    private static func fenceMarker(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.distance(from: line.startIndex, to: trimmed.startIndex) <= 3 else { return nil }
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isFence(_ line: String, marker: String) -> Bool {
        line.drop(while: { $0 == " " }).hasPrefix(marker)
    }

    private static func replacingOpaqueCitations(in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var fence: String?
        return lines.map { line in
            if let marker = fence {
                if isFence(line, marker: marker) { fence = nil }
                return line
            }
            if let marker = fenceMarker(in: line) {
                fence = marker
                return line
            }
            return replacingOpaqueCitationsInText(line)
        }.joined(separator: "\n")
    }

    private static func replacingOpaqueCitationsInText(_ source: String) -> String {
        let start = Character("\u{E200}")
        let separator = Character("\u{E202}")
        let end = Character("\u{E201}")
        var output = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == start,
                  source.index(after: index) < source.endIndex,
                  source[source.index(after: index)...].hasPrefix("cite") else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }
            var cursor = source.index(index, offsetBy: 5)
            var referenceCount = 0
            while cursor < source.endIndex, source[cursor] == separator {
                cursor = source.index(after: cursor)
                let referenceStart = cursor
                while cursor < source.endIndex, source[cursor] != separator, source[cursor] != end {
                    cursor = source.index(after: cursor)
                }
                guard cursor > referenceStart else { break }
                referenceCount += 1
            }
            guard referenceCount > 0, cursor < source.endIndex, source[cursor] == end else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }
            output.append("[Source unavailable]")
            index = source.index(after: cursor)
        }
        return output
    }

    private static func decorateTokens(in source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        let expression = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])(?:~?/[^\\s`<>]+|(?:\\.?\\.?/)?[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+|[A-Za-z0-9_.-]+\\.(?:swift|md|json|yaml|yml|txt|js|ts|py|rs|c|h))(?![A-Za-z0-9_])"
        )
        expression?.enumerateMatches(in: result.string, range: fullRange) { match, _, _ in
            guard let match,
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { return }
            let existingFont = result.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont
            let isCodeFont = existingFont?.fontName.localizedCaseInsensitiveContains("mono") == true
            let paragraph = (result.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle
            paragraph?.lineBreakMode = .byCharWrapping
            result.addAttributes([
                .foregroundColor: isCodeFont ? NSColor.systemIndigo : NSColor.systemPurple,
                .font: NSFont.monospacedSystemFont(ofSize: existingFont?.pointSize ?? NSFont.smallSystemFontSize, weight: .regular)
            ], range: match.range)
            if let paragraph {
                result.addAttribute(.paragraphStyle, value: paragraph, range: match.range)
            }
        }
        return result
    }

    private enum BlockKind: Equatable { case heading(Int), paragraph, listItem(Int?, Bool), quote, code }
    private struct Block: Equatable { let id: String; let kind: BlockKind }

    /// Foundation intentionally returns semantic runs without visual paragraph
    /// separators or list bullets. Reassemble only those block boundaries from
    /// its presentation intents; parsing of Markdown syntax remains Foundation's.
    private static func style(_ markdown: AttributedString) -> NSAttributedString {
        let bridged = NSAttributedString(markdown)
        let result = NSMutableAttributedString()
        let runs = Array(markdown.runs)

        for (index, run) in runs.enumerated() {
            let range = NSRange(run.range, in: markdown)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let renderingBlock = block(for: run)
            let previous = index > 0 ? block(for: runs[index - 1]) : nil
            if previous != nil, previous != renderingBlock, !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n"))
            }
            if previous != renderingBlock, case let .listItem(ordinal, ordered)? = renderingBlock?.kind {
                let marker = ordered ? "\(ordinal ?? 1). " : "• "
                result.append(NSAttributedString(string: marker, attributes: listMarkerAttributes()))
            }

            let attributes = bridged.attributes(at: range.location, effectiveRange: nil)
            let segment = NSMutableAttributedString(string: String(markdown[run.range].characters), attributes: attributes)
            let inline = run.inlinePresentationIntent
            applyStyle(to: segment,
                       block: renderingBlock,
                       isInlineCode: inline?.contains(.code) == true,
                       isBold: inline?.contains(.stronglyEmphasized) == true,
                       isItalic: inline?.contains(.emphasized) == true)
            result.append(segment)

            let next = index + 1 < runs.count ? block(for: runs[index + 1]) : nil
            if renderingBlock != next, !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func block(for run: AttributedString.Runs.Run) -> Block? {
        guard let intent = run.presentationIntent else { return nil }
        var listItem: (String, Int?)?
        var isOrdered = false
        var fallback: Block?
        for component in intent.components {
            let id = String(component.identity)
            switch component.kind {
            case let .header(level): fallback = Block(id: id, kind: .heading(level))
            case .paragraph: fallback = Block(id: id, kind: .paragraph)
            case .blockQuote: fallback = Block(id: id, kind: .quote)
            case .codeBlock: fallback = Block(id: id, kind: .code)
            case let .listItem(ordinal): listItem = (id, ordinal)
            case .orderedList: isOrdered = true
            default: break
            }
        }
        if let listItem { return Block(id: listItem.0, kind: .listItem(listItem.1, isOrdered)) }
        return fallback
    }

    private static func applyStyle(to text: NSMutableAttributedString,
                                   block: Block?,
                                   isInlineCode: Bool,
                                   isBold: Bool,
                                   isItalic: Bool) {
        let range = NSRange(location: 0, length: text.length)
        guard range.length > 0 else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.textColor
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.lineBreakMode = .byWordWrapping
        switch block?.kind {
        case let .heading(level):
            let sizes: [CGFloat] = [28, 24, 20, 18, 16, 14]
            attributes[.font] = NSFont.systemFont(ofSize: sizes[max(0, min(level - 1, sizes.count - 1))], weight: .bold)
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 8
        case .listItem:
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 22
        case .quote:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            paragraph.headIndent = 16
            paragraph.firstLineHeadIndent = 16
        case .code:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            attributes[.backgroundColor] = NSColor.controlBackgroundColor
            paragraph.paragraphSpacing = 12
            paragraph.lineBreakMode = .byCharWrapping
        default: break
        }
        if isInlineCode {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            attributes[.backgroundColor] = NSColor.controlBackgroundColor
            paragraph.lineBreakMode = .byCharWrapping
        } else {
            var font = attributes[.font] as! NSFont
            if isBold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if isItalic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
        }
        attributes[.paragraphStyle] = paragraph
        text.addAttributes(attributes, range: range)
    }

    private static func listMarkerAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
    }
}
