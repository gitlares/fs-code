import AppKit
import EditorCore

/// Syntax attributes are presentation only; saving and undo operate on plain text.
@MainActor final class CodePresentation {
    let ruler: LineNumberRulerView
    private(set) var language: SourceLanguage = .plainText
    var onLanguageChange: (() -> Void)?

    private let textView: CodeTextView
    private let url: URL
    private var palette: EditorPalette
    private var tokens: [SyntaxToken] = []
    private var revision = 0
    private var highlightTask: Task<Void, Never>?
    private var worker: Task<[SyntaxToken], Never>?

    init(textView: CodeTextView, scrollView: NSScrollView, url: URL) {
        self.textView = textView
        self.url = url
        palette = EditorPalette(appearance: textView.effectiveAppearance)
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        textView.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        applyAppearance()
        updateSyntax()
    }

    deinit {
        highlightTask?.cancel()
        worker?.cancel()
    }

    func textDidChange() {
        ruler.textDidChange()
        // Offsets from an earlier text revision must never be applied to new text.
        tokens.removeAll(keepingCapacity: true)
        updateSyntax()
    }

    func setAgentChangeRanges(_ ranges: [NSRange]) {
        let validRanges = ranges.filter {
            $0.location != NSNotFound && NSMaxRange($0) <= textView.string.utf16.count
        }
        textView.agentChangeRanges = validRanges
        ruler.setAgentChangeRanges(validRanges)
    }

    private func updateSyntax() {
        revision += 1
        let expectedRevision = revision
        highlightTask?.cancel()
        worker?.cancel()
        let firstLine = String(textView.string.prefix(512).prefix { !$0.isNewline })
        let detected = SourceLanguage.detect(url: url, firstLine: firstLine)
        if detected != language {
            language = detected
            onLanguageChange?()
        }
        guard language != .plainText else { invalidateColors(); return }
        highlightTask = Task { [weak self] in
            // Avoid Swift 6.4 task-slab corruption from the Duration overload (swift#86204).
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            let text = self.textView.string
            let language = self.language
            let worker = Task.detached(priority: .userInitiated) {
                SyntaxTokenizer.tokenize(text, language: language)
            }
            self.worker = worker
            let result = await worker.value
            guard !Task.isCancelled, self.revision == expectedRevision else { return }
            self.tokens = result
            self.invalidateColors()
        }
    }

    private func applyAppearance() {
        palette = EditorPalette(appearance: textView.effectiveAppearance)
        textView.backgroundColor = palette.background
        textView.currentLineColor = palette.currentLine
        textView.agentChangeColor = NSColor.systemOrange.withAlphaComponent(0.16)
        textView.enclosingScrollView?.backgroundColor = palette.background
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        textView.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.foreground]
        ruler.applyColors(background: palette.background, foreground: palette.comment)
        invalidateColors()
    }

    private func invalidateColors() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        // Direct storage attributes do not register an undo operation or change the
        // plain-text buffer. Batch them so TextKit processes a single style update.
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: palette.foreground,
                             range: NSRange(location: 0, length: storage.length))
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }

    private func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword, .operator, .tag: palette.pink
        case .string: palette.yellow
        case .comment: palette.comment
        case .number: palette.purple
        case .type: palette.cyan
        case .function: palette.green
        case .property, .attribute: palette.green
        }
    }
}
