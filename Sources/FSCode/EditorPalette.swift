import AppKit

/// Dracula and its light companion Alucard. See Resources/ThirdPartyNotices.txt.
@MainActor struct EditorPalette {
    let background: NSColor
    let foreground: NSColor
    let selection: NSColor
    var currentLine: NSColor { selection.withAlphaComponent(0.35) }
    let comment: NSColor
    let cyan: NSColor
    let green: NSColor
    let orange: NSColor
    let pink: NSColor
    let purple: NSColor
    let yellow: NSColor

    init(appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        background = Self.color(dark ? 0x282a36 : 0xfffbeb)
        foreground = Self.color(dark ? 0xf8f8f2 : 0x1f1f1f)
        selection = Self.color(dark ? 0x44475a : 0xcfcfde)
        comment = Self.color(dark ? 0x6272a4 : 0x6c664b)
        cyan = Self.color(dark ? 0x8be9fd : 0x036a96)
        green = Self.color(dark ? 0x50fa7b : 0x14710a)
        orange = Self.color(dark ? 0xffb86c : 0xa34d14)
        pink = Self.color(dark ? 0xff79c6 : 0xa3144d)
        purple = Self.color(dark ? 0xbd93f9 : 0x644ac9)
        yellow = Self.color(dark ? 0xf1fa8c : 0x846e15)
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

@MainActor final class CodeTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?
    var currentLineColor = NSColor.clear
    var agentChangeColor = NSColor.systemOrange.withAlphaComponent(0.16)
    var agentChangeRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }
    private var previousLineRect: NSRect?

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
}
