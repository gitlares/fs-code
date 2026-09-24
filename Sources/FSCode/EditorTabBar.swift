import AppKit

/// A compact, horizontally scrolling document tab strip for the editor.
///
/// The strip deliberately uses ordinary AppKit buttons: filenames remain readable,
/// every close action is separately focusable, and system colours track the current
/// appearance and accessibility settings.
@MainActor
final class EditorTabBar: NSView {
    struct Item {
        let url: URL
        let title: String
        let isDirty: Bool
        let isAgentModified: Bool
    }

    var onSelect: ((URL) -> Void)?
    var onClose: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let stripView = StripView()
    private let separator = NSView()
    private var tabViews: [URL: TabView] = [:]
    private var orderedURLs: [URL] = []
    private var selectedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = stripView
        addSubview(scrollView)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open files")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let separatorHeight = 1 / max(window?.backingScaleFactor ?? 1, 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - separatorHeight))
        separator.frame = NSRect(x: 0, y: bounds.height - separatorHeight, width: bounds.width, height: separatorHeight)
        stripView.layoutTabs(viewportWidth: scrollView.contentView.bounds.width, height: scrollView.contentView.bounds.height)
    }

    /// Reconciles the visible tabs with the editor's open documents.
    func update(items: [Item], selectedURL: URL?) {
        let oldURLs = Set(orderedURLs)
        let selectedChanged = self.selectedURL != selectedURL
        let selectedWasAdded = selectedURL.map { !oldURLs.contains($0) } ?? false
        let incomingURLs = Set(items.map(\.url))

        let removedURLs = tabViews.keys.filter { !incomingURLs.contains($0) }
        for url in removedURLs {
            tabViews[url]?.removeFromSuperview()
            tabViews.removeValue(forKey: url)
        }

        let tabs: [TabView] = items.map { item in
            let tab = tabViews[item.url] ?? makeTab(for: item)
            tab.configure(item: item, selected: item.url == selectedURL)
            tabViews[item.url] = tab
            return tab
        }
        orderedURLs = items.map(\.url)
        self.selectedURL = selectedURL
        stripView.setTabs(tabs)
        needsLayout = true
        layoutSubtreeIfNeeded()

        // A dirty-state refresh must leave the current scroll position alone.
        if let selectedURL, selectedChanged || selectedWasAdded {
            DispatchQueue.main.async { [weak self] in
                self?.scrollTabIntoView(url: selectedURL)
            }
        }
    }

    private func makeTab(for item: Item) -> TabView {
        let tab = TabView(url: item.url)
        tab.onSelect = { [weak self] url in self?.onSelect?(url) }
        tab.onClose = { [weak self] url in self?.onClose?(url) }
        return tab
    }

    private func scrollTabIntoView(url: URL) {
        guard let tab = tabViews[url] else { return }
        tab.scrollToVisible(tab.bounds.insetBy(dx: -8, dy: 0))
    }
}

@MainActor
private final class StripView: NSView {
    private let horizontalInset: CGFloat = 5
    private let tabSpacing: CGFloat = 2
    private var tabs: [TabView] = []

    override var isFlipped: Bool { true }

    func setTabs(_ tabs: [TabView]) {
        self.tabs = tabs
        subviews.filter { view in !tabs.contains { $0 === view } }.forEach { $0.removeFromSuperview() }
        for tab in tabs where tab.superview !== self { addSubview(tab) }
        needsLayout = true
    }

    func layoutTabs(viewportWidth: CGFloat, height: CGFloat) {
        var x = horizontalInset
        let tabHeight = min(30, max(24, height - 4))
        for tab in tabs {
            let width = tab.preferredWidth
            tab.frame = NSRect(x: x, y: max(2, (height - tabHeight) / 2), width: width, height: tabHeight)
            x += width + tabSpacing
        }
        let contentWidth = max(viewportWidth, x + horizontalInset - tabSpacing)
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
    }
}

@MainActor
private final class TabView: NSView {
    let url: URL
    var onSelect: ((URL) -> Void)?
    var onClose: ((URL) -> Void)?

    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let agentChangeIndicator = NSImageView()
    private let dirtyIndicator = NSImageView()
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private(set) var preferredWidth: CGFloat = 110
    private var selected = false

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 12)
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.imagePosition = .imageLeading
        titleButton.imageScaling = .scaleProportionallyDown
        titleButton.image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        titleButton.image?.size = NSSize(width: 16, height: 16)
        titleButton.alignment = .left
        titleButton.target = self
        titleButton.action = #selector(selectTab)
        titleButton.setAccessibilityLabel("Document tab")
        addSubview(titleButton)

        agentChangeIndicator.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Modified by approved agent change")
        agentChangeIndicator.contentTintColor = .systemPurple
        agentChangeIndicator.setAccessibilityLabel("Modified by approved agent change")
        agentChangeIndicator.toolTip = "Modified by an approved agent change"
        agentChangeIndicator.setAccessibilityElement(true)
        addSubview(agentChangeIndicator)

        dirtyIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved changes")
        dirtyIndicator.contentTintColor = .controlAccentColor
        dirtyIndicator.setAccessibilityLabel("Unsaved changes")
        dirtyIndicator.toolTip = "Unsaved changes"
        dirtyIndicator.setAccessibilityElement(true)
        addSubview(dirtyIndicator)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel("Close document")
        addSubview(closeButton)

        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 22
        let dirtySize: CGFloat = 8
        let agentSize: CGFloat = 11
        let closeX = bounds.width - closeSize - 3
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        dirtyIndicator.frame = NSRect(
            x: closeX - dirtySize - 3,
            y: (bounds.height - dirtySize) / 2,
            width: dirtySize,
            height: dirtySize
        )
        agentChangeIndicator.frame = NSRect(
            x: dirtyIndicator.frame.minX - agentSize - 4,
            y: (bounds.height - agentSize) / 2,
            width: agentSize,
            height: agentSize
        )
        titleButton.frame = NSRect(x: 6, y: 1, width: max(0, agentChangeIndicator.frame.minX - 9), height: bounds.height - 2)
    }

    func configure(item: EditorTabBar.Item, selected: Bool) {
        let title = item.title.isEmpty ? item.url.lastPathComponent : item.title
        titleButton.title = title
        titleButton.setAccessibilityLabel(title)
        titleButton.setAccessibilityValue([
            selected ? "Selected" : nil,
            item.isDirty ? "Unsaved changes" : nil,
            item.isAgentModified ? "Modified by AI" : nil
        ].compactMap { $0 }.joined(separator: ", "))
        titleButton.toolTip = item.url.path
        closeButton.toolTip = "Close \(title)"
        closeButton.setAccessibilityLabel("Close \(title)")
        setAccessibilityLabel(title)
        setAccessibilityHelp(item.url.path)
        setAccessibilitySelected(selected)
        dirtyIndicator.isHidden = !item.isDirty
        agentChangeIndicator.isHidden = !item.isAgentModified

        let titleWidth = (title as NSString).size(withAttributes: [.font: titleButton.font ?? .systemFont(ofSize: 12)]).width
        // Includes a document icon, dirty marker, close control, and compact padding.
        preferredWidth = min(200, max(110, ceil(titleWidth) + 80))
        self.selected = selected
        updateColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlBackgroundColor : .clear).cgColor
        }
    }

    @objc private func selectTab() { onSelect?(url) }

    @objc private func closeTab() { onClose?(url) }
}
