import AppKit
import EditorCore

/// A TextKit 2 ruler that labels only the logical starts of visible lines.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndex = LineIndex()
    private var foregroundColor = NSColor.secondaryLabelColor
    private var backgroundColor = NSColor.textBackgroundColor
    private var currentLineForegroundColor = NSColor.labelColor
    private var agentChangeRanges: [NSRange] = []
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let agentChangeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private var notificationObservers: [NSObjectProtocol] = []

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)

        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        updateLineIndex()
        updateThickness()

        scrollView.verticalRulerView = self
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let notificationCenter = NotificationCenter.default
        notificationObservers = [
            notificationCenter.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            },
            notificationCenter.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            }
        ]
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    isolated deinit {
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    override var isFlipped: Bool { true }

    func textDidChange() {
        updateLineIndex()
        updateThickness()
        needsDisplay = true
    }

    func selectionDidChange() {
        // Selection changes can scroll the editor without producing a text edit.
        needsDisplay = true
    }

    func position(atUTF16Offset offset: Int) -> (line: Int, column: Int) {
        lineIndex.position(atUTF16Offset: offset)
    }

    func applyColors(background: NSColor, foreground: NSColor, currentLineForeground: NSColor? = nil) {
        backgroundColor = background
        foregroundColor = foreground
        currentLineForegroundColor = currentLineForeground ?? foreground
        needsDisplay = true
    }

    func setAgentChangeRanges(_ ranges: [NSRange]) {
        agentChangeRanges = ranges
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        backgroundColor.setFill()
        bounds.fill()
        if let editor = textView as? CodeTextView, let line = editor.currentLineRect {
            let row = convert(line, from: editor)
            editor.currentLineColor.setFill()
            NSRect(x: bounds.minX, y: row.minY, width: bounds.width, height: row.height).intersection(bounds).fill()
        }

        guard let textView,
              let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager,
              let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange else {
            return
        }

        let selectedLine = lineIndex.position(atUTF16Offset: textView.selectedRange().location).line
        let endLocation = viewportRange.endLocation
        textLayoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: [.ensuresExtraLineFragment]
        ) { [weak self, weak textView] fragment in
            guard let self, let textView else { return false }
            guard fragment.rangeInElement.location.compare(endLocation) != .orderedDescending else { return false }
            let paragraphOffset = textContentManager.offset(
                from: textContentManager.documentRange.location,
                to: fragment.rangeInElement.location
            )
            guard paragraphOffset != NSNotFound else { return true }

            for lineFragment in fragment.textLineFragments {
                let characterOffset = paragraphOffset + lineFragment.characterRange.location
                guard self.lineIndex.lineStarts.binarySearch(contains: characterOffset) else { continue }

                let lineNumber = self.lineIndex.lineNumber(atUTF16Offset: characterOffset)
                let label = NSAttributedString(
                    string: String(lineNumber),
                    attributes: [
                        .font: numberFont,
                        .foregroundColor: lineNumber == selectedLine ? currentLineForegroundColor : foregroundColor
                    ]
                )
                let labelSize = label.size()
                let textRect = lineFragment.typographicBounds.offsetBy(
                    dx: textView.textContainerOrigin.x + fragment.layoutFragmentFrame.minX,
                    dy: textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                )
                let rulerRect = self.convert(textRect, from: textView)
                let y = rulerRect.midY - labelSize.height / 2
                let x = self.bounds.maxX - labelSize.width - 6

                guard NSIntersectsRect(NSRect(x: 0, y: y, width: self.bounds.width, height: labelSize.height), rect) else { continue }
                let lineRange = NSRange(
                    location: characterOffset,
                    length: lineFragment.characterRange.length
                )
                if self.agentChangeRanges.contains(where: {
                    NSIntersectionRange($0, lineRange).length > 0
                        || ($0.length == 0 && (NSLocationInRange($0.location, lineRange)
                            || $0.location == NSMaxRange(lineRange)))
                }) {
                    NSAttributedString(
                        string: "✦",
                        attributes: [
                            .font: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                                ? NSFont.systemFont(ofSize: 11, weight: .bold)
                                : self.agentChangeFont,
                            .foregroundColor: NSColor.controlAccentColor
                        ]
                    ).draw(at: NSPoint(x: 3, y: y))
                }
                label.draw(at: NSPoint(x: x, y: y))
            }
            return true
        }
    }

    private func updateLineIndex() {
        lineIndex.update(for: textView?.string ?? "")
    }

    private func updateThickness() {
        let digits = String(lineIndex.lineCount).count
        let widestLabel = String(repeating: "8", count: max(2, digits)) as NSString
        ruleThickness = ceil(widestLabel.size(withAttributes: [.font: numberFont]).width) + 22
    }
}

private extension Array where Element == Int {
    func binarySearch(contains value: Int) -> Bool {
        var lowerBound = 0
        var upperBound = count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if self[midpoint] == value { return true }
            if self[midpoint] < value {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return false
    }
}
