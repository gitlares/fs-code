import AppKit
import EditorCore

/// Editor-only colors. `init(appearance:)` deliberately remains on the bundled
/// pair so tabs and other native chrome never inherit an imported text theme.
@MainActor
struct EditorPalette {
    let background: NSColor
    let foreground: NSColor
    let currentLine: NSColor
    let comment: NSColor
    let currentLineNumber: NSColor
    let cursor: NSColor
    let ansiColors: [NSColor]
    private let theme: EditorTheme

    init(appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.init(theme: dark ? .dracula : .alucard)
    }

    init(theme: EditorTheme) {
        self.theme = theme
        background = Self.color(theme.background)
        foreground = Self.color(theme.foreground)
        currentLine = Self.color(theme.currentLine)
        comment = Self.color(theme.comment)
        currentLineNumber = Self.color(theme.currentLineNumber)
        cursor = Self.color(theme.cursor)
        ansiColors = theme.ansiColors.map(Self.color)
    }

    func color(for kind: SyntaxTokenKind) -> NSColor {
        Self.color(theme.tokenColor(for: kind))
    }

    private static func color(_ rgb: ThemeRGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: rgb.alpha
        )
    }
}

@MainActor final class CodeTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?
    var onSelectionFocusChange: ((Bool) -> Void)?
    var currentLineColor = NSColor.clear
    var agentChangeColor = NSColor.controlAccentColor.withAlphaComponent(0.16)
    var agentChangeRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }
    private var previousLineRect: NSRect?
    private var windowObservers: [NSObjectProtocol] = []

    /// The visual row containing the insertion point; no attributes or undo edits.
    var currentLineRect: NSRect? {
        let selection = selectedRange()
        guard selection.length == 0, selection.location != NSNotFound,
              let manager = textLayoutManager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: selection.location),
              let fragment = manager.textLayoutFragment(for: location),
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: selectionAffinity == .upstream) else { return nil }
        let y = textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        return NSRect(x: bounds.minX, y: y, width: bounds.width, height: line.typographicBounds.height)
    }

    func refreshCurrentLine() {
        if let previousLineRect { setNeedsDisplay(previousLineRect) }
        previousLineRect = currentLineRect
        if let previousLineRect { setNeedsDisplay(previousLineRect) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawAgentChangeRanges(in: rect)
        previousLineRect = currentLineRect
        guard let line = previousLineRect, line.intersects(rect) else { return }
        currentLineColor.setFill()
        line.intersection(rect).fill()
    }

    private func drawAgentChangeRanges(in dirtyRect: NSRect) {
        guard !agentChangeRanges.isEmpty,
              let textLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange else { return }
        let documentLocation = contentManager.documentRange.location
        let endLocation = viewportRange.endLocation
        textLayoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: [.ensuresExtraLineFragment]
        ) { [weak self] fragment in
            guard let self else { return false }
            guard fragment.rangeInElement.location.compare(endLocation) != .orderedDescending else { return false }
            let fragmentOffset = contentManager.offset(
                from: documentLocation,
                to: fragment.rangeInElement.location
            )
            guard fragmentOffset != NSNotFound else { return true }
            for line in fragment.textLineFragments {
                let lineRange = NSRange(
                    location: fragmentOffset + line.characterRange.location,
                    length: line.characterRange.length
                )
                guard self.agentChangeRanges.contains(where: {
                    NSIntersectionRange($0, lineRange).length > 0
                        || ($0.length == 0 && (NSLocationInRange($0.location, lineRange)
                            || $0.location == NSMaxRange(lineRange)))
                }) else { continue }
                let lineRect = line.typographicBounds.offsetBy(
                    dx: self.textContainerOrigin.x + fragment.layoutFragmentFrame.minX,
                    dy: self.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                )
                guard lineRect.intersects(dirtyRect) else { continue }
                self.agentChangeColor.setFill()
                lineRect.intersection(dirtyRect).fill()
            }
            return true
        }
    }


    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let currentWindow = self.window else { return }
                    let focused = currentWindow.isKeyWindow && currentWindow.firstResponder === self
                    self.onSelectionFocusChange?(focused)
                }
            })
        }
    }

    isolated deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onSelectionFocusChange?(window?.isKeyWindow == true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onSelectionFocusChange?(false) }
        return accepted
    }
}
