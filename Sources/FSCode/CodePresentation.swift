import AppKit
import EditorCore

/// Syntax attributes are presentation only; saving and undo operate on plain text.
@MainActor final class CodePresentation {
    let ruler: LineNumberRulerView
    private(set) var language: SourceLanguage = .plainText
    private(set) var tokenizationCount = 0
    var onLanguageChange: (() -> Void)?

    private let textView: CodeTextView
    private let url: URL
    private var palette: EditorPalette
    private let themeStore = EditorThemeStore.shared
    private var themeObserver: NSObjectProtocol?
    private var tokens: [SyntaxToken] = []
    private var revision = 0
    private var highlightTask: Task<Void, Never>?
    private var worker: Task<[SyntaxToken], Never>?
    private var recolorTask: Task<Void, Never>?
    private var recolorWorker: Task<[RecolorBatch], Never>?
    private var themeGeneration = 0

    init(textView: CodeTextView, scrollView: NSScrollView, url: URL) {
        self.textView = textView
        self.url = url
        palette = EditorPalette(appearance: textView.effectiveAppearance)
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        textView.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        textView.onSelectionFocusChange = { [weak self] focused in self?.applySelectionAppearance(focused: focused) }
        themeObserver = NotificationCenter.default.addObserver(
            forName: .editorThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        applyAppearance()
        updateSyntax()
    }

    isolated deinit {
        highlightTask?.cancel()
        worker?.cancel()
        recolorTask?.cancel()
        recolorWorker?.cancel()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func textDidChange() {
        ruler.textDidChange()
        // Offsets from an earlier text revision must never be applied to new text.
        themeGeneration &+= 1
        recolorTask?.cancel()
        recolorWorker?.cancel()
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
            self.tokenizationCount += 1
            let worker = Task.detached(priority: .userInitiated) {
                SyntaxTokenizer.tokenize(text, language: language)
            }
            self.worker = worker
            let result = await worker.value
            guard !Task.isCancelled, self.revision == expectedRevision else { return }
            self.themeGeneration &+= 1
            self.recolorTask?.cancel()
            self.recolorWorker?.cancel()
            self.tokens = result
            self.invalidateColors()
        }
    }

    private func applyAppearance() {
        themeGeneration &+= 1
        let generation = themeGeneration
        recolorTask?.cancel()
        recolorWorker?.cancel()
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        palette = EditorPalette(theme: themeStore.activeTheme(forDarkAppearance: dark))
        textView.backgroundColor = palette.background
        textView.currentLineColor = palette.currentLine
        textView.agentChangeColor = NSColor.controlAccentColor.withAlphaComponent(0.16)
        textView.enclosingScrollView?.backgroundColor = palette.background
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        applySelectionAppearance(focused: textView.window?.firstResponder === textView && textView.window?.isKeyWindow == true)
        ruler.applyColors(
            background: palette.background,
            foreground: palette.comment,
            currentLineForeground: palette.currentLineNumber
        )
        invalidateColors(visibleOnly: true)
        scheduleRemainingColors(generation: generation)
    }

    private func scheduleRemainingColors(generation: Int) {
        let length = textView.textStorage?.length ?? 0
        let tokenSnapshot = tokens
        guard length > 0 else { return }
        recolorTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                Self.recolorBatches(length: length, tokens: tokenSnapshot)
            }
            self?.recolorWorker = worker
            let batches = await worker.value
            for batch in batches {
                guard !Task.isCancelled,
                      !worker.isCancelled,
                      let self,
                      self.themeGeneration == generation,
                      self.textView.textStorage?.length == length else { return }
                self.applyColors(in: batch.range, tokens: batch.tokens)
                await Task.yield()
            }
        }
    }

    nonisolated private static func recolorBatches(length: Int, tokens: [SyntaxToken]) -> [RecolorBatch] {
        let chunkSize = 4_096
        let count = (length + chunkSize - 1) / chunkSize
        var tokenBuckets = Array(repeating: [SyntaxToken](), count: count)
        for token in tokens {
            guard !Task.isCancelled else { return [] }
            guard token.range.location < length, token.range.length > 0 else { continue }
            let first = max(0, token.range.location / chunkSize)
            let last = min(count - 1, (NSMaxRange(token.range) - 1) / chunkSize)
            guard first <= last else { continue }
            for index in first...last { tokenBuckets[index].append(token) }
        }
        return (0..<count).map { index in
            guard !Task.isCancelled else { return RecolorBatch(range: .init(location: 0, length: 0), tokens: []) }
            let start = index * chunkSize
            let range = NSRange(location: start, length: min(chunkSize, length - start))
            return RecolorBatch(range: range, tokens: tokenBuckets[index])
        }
    }

    private func applySelectionAppearance(focused: Bool) {
        let background = focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        let foreground = focused ? NSColor.selectedTextColor : NSColor.unemphasizedSelectedTextColor
        textView.selectedTextAttributes = [.backgroundColor: background, .foregroundColor: foreground]
    }

    private func invalidateColors(visibleOnly: Bool = false) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let targetRange: NSRange
        if visibleOnly,
           let layout = textView.textLayoutManager,
           let content = layout.textContentManager,
           let viewport = layout.textViewportLayoutController.viewportRange {
            let rawStart = content.offset(from: content.documentRange.location, to: viewport.location)
            let rawEnd = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            if rawStart == NSNotFound || rawEnd == NSNotFound {
                targetRange = NSRange(location: 0, length: storage.length)
            } else {
                let start = min(max(0, rawStart), storage.length)
                let end = min(max(start, rawEnd), storage.length)
                targetRange = NSRange(location: start, length: end - start)
            }
        } else { targetRange = NSRange(location: 0, length: storage.length) }
        // Direct storage attributes do not register an undo operation or change the
        // plain-text buffer. Batch them so TextKit processes a single style update.
        applyColors(in: targetRange, tokens: tokens)
    }

    private func applyColors(in targetRange: NSRange, tokens: [SyntaxToken]) {
        guard let storage = textView.textStorage, targetRange.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: palette.foreground, range: targetRange)
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            let appliedRange = NSIntersectionRange(token.range, targetRange)
            guard appliedRange.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: appliedRange)
        }
        storage.endEditing()
    }

    private func color(for kind: SyntaxTokenKind) -> NSColor {
        palette.color(for: kind)
    }
}

private struct RecolorBatch: Sendable {
    let range: NSRange
    let tokens: [SyntaxToken]
}
