import AppKit

/// Minimal shape a tab strip needs from its model type. Identity comes from `id`
/// (a file `URL`, a chat `UUID`, ...); everything else is supplied through
/// `TabStripConfiguration` closures so one strip implementation can render both.
protocol TabStripItem {
    associatedtype ID: Hashable
    var id: ID { get }
    var title: String { get }
}

/// Optional per-tab status glyphs, shown next to the close button.
enum TabStripAccessory: Hashable {
    case dirty
    case agentModified
}

/// Everything a `TabStripView` needs to know to render and size one kind of tab,
/// without knowing anything about files or chat threads itself.
struct TabStripConfiguration<Item: TabStripItem> {
    var icon: (Item) -> NSImage?
    var tooltip: (Item) -> String = { $0.title }
    var accessibilityHelp: (Item) -> String? = { _ in nil }
    var accessories: (Item) -> Set<TabStripAccessory> = { _ in [] }
    var isSelectable: (Item) -> Bool = { _ in true }
    var isClosable: (Item) -> Bool = { _ in true }
    var closeTooltip: (Item) -> String = { "Close \($0.title)" }
    var selectedBackground: (NSAppearance) -> NSColor = { _ in .textBackgroundColor }
    var minWidth: CGFloat = 108
    var maxWidth: CGFloat = 210
    var chromeWidth: CGFloat = 58
    var horizontalInset: CGFloat = 5
    /// Header material + bottom separator, matching the editor tab bar's chrome.
    /// Off by default (the chat tab strip is transparent over its own container).
    var showsChrome: Bool = false
    var accessibilityGroupLabel: String = "Tabs"

    init(
        icon: @escaping (Item) -> NSImage?,
        tooltip: @escaping (Item) -> String = { $0.title },
        accessibilityHelp: @escaping (Item) -> String? = { _ in nil },
        accessories: @escaping (Item) -> Set<TabStripAccessory> = { _ in [] },
        isSelectable: @escaping (Item) -> Bool = { _ in true },
        isClosable: @escaping (Item) -> Bool = { _ in true },
        closeTooltip: @escaping (Item) -> String = { "Close \($0.title)" },
        selectedBackground: @escaping (NSAppearance) -> NSColor = { _ in .textBackgroundColor },
        minWidth: CGFloat = 108,
        maxWidth: CGFloat = 210,
        chromeWidth: CGFloat = 58,
        horizontalInset: CGFloat = 5,
        showsChrome: Bool = false,
        accessibilityGroupLabel: String = "Tabs"
    ) {
        self.icon = icon
        self.tooltip = tooltip
        self.accessibilityHelp = accessibilityHelp
        self.accessories = accessories
        self.isSelectable = isSelectable
        self.isClosable = isClosable
        self.closeTooltip = closeTooltip
        self.selectedBackground = selectedBackground
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.chromeWidth = chromeWidth
        self.horizontalInset = horizontalInset
        self.showsChrome = showsChrome
        self.accessibilityGroupLabel = accessibilityGroupLabel
    }
}

/// A compact, horizontally scrolling tab strip. Used for both the editor's open
/// documents and the chat's open conversations; everything file- or chat-specific
/// lives in the `TabStripConfiguration` each wrapper provides.
@MainActor
final class TabStripView<Item: TabStripItem>: NSView {
    var onSelect: ((Item.ID) -> Void)?
    var onClose: ((Item.ID) -> Void)?

    private let configuration: TabStripConfiguration<Item>
    private let scrollView = NSScrollView()
    private let strip: TabStripContainer<Item>
    private let separator = NSView()
    private let material = NSVisualEffectView()
    private var accessibilityObserver: NSObjectProtocol?
    private var cells: [Item.ID: TabStripCell<Item>] = [:]
    private var orderedIDs: [Item.ID] = []
    private var selectedID: Item.ID?

    init(configuration: TabStripConfiguration<Item>) {
        self.configuration = configuration
        strip = TabStripContainer(horizontalInset: configuration.horizontalInset)
        super.init(frame: .zero)
        wantsLayer = true

        if configuration.showsChrome {
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            addSubview(material)

            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            addSubview(separator)

            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAccessibilityColors() }
            }
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = strip
        addSubview(scrollView)

        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(configuration.accessibilityGroupLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    isolated deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard configuration.showsChrome else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    private func refreshAccessibilityColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        cells.values.forEach { $0.updateColors() }
    }

    override func layout() {
        super.layout()
        if configuration.showsChrome {
            material.frame = bounds
            let separatorHeight = 1 / max(window?.backingScaleFactor ?? 1, 1)
            scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - separatorHeight))
            separator.frame = NSRect(x: 0, y: bounds.height - separatorHeight, width: bounds.width, height: separatorHeight)
        } else {
            scrollView.frame = bounds
        }
        strip.layoutTabs(viewportWidth: scrollView.contentView.bounds.width, height: scrollView.contentView.bounds.height)
    }

    /// Reconciles the visible tabs with the caller's current items.
    func update(items: [Item], selectedID: Item.ID?) {
        let oldIDs = Set(orderedIDs)
        let selectionChanged = self.selectedID != selectedID
        let selectionWasAdded = selectedID.map { !oldIDs.contains($0) } ?? false
        let incomingIDs = Set(items.map(\.id))

        let removedIDs = cells.keys.filter { !incomingIDs.contains($0) }
        for id in removedIDs {
            cells[id]?.removeFromSuperview()
            cells.removeValue(forKey: id)
        }

        let tabs: [TabStripCell<Item>] = items.map { item in
            let cell = cells[item.id] ?? makeCell()
            cell.configure(configuration: configuration, item: item, selected: item.id == selectedID)
            cells[item.id] = cell
            return cell
        }
        orderedIDs = items.map(\.id)
        self.selectedID = selectedID
        strip.setTabs(tabs)
        needsLayout = true
        layoutSubtreeIfNeeded()

        // A status-only refresh (e.g. dirty state) must leave scroll position alone.
        if let selectedID, selectionChanged || selectionWasAdded {
            DispatchQueue.main.async { [weak self] in
                self?.scrollTabIntoView(id: selectedID)
            }
        }
    }

    private func makeCell() -> TabStripCell<Item> {
        let cell = TabStripCell<Item>()
        cell.onSelect = { [weak self] id in self?.onSelect?(id) }
        cell.onClose = { [weak self] id in self?.onClose?(id) }
        return cell
    }

    private func scrollTabIntoView(id: Item.ID) {
        guard let cell = cells[id] else { return }
        cell.scrollToVisible(cell.bounds.insetBy(dx: -8, dy: 0))
    }
}

@MainActor
private final class TabStripContainer<Item: TabStripItem>: NSView {
    private let horizontalInset: CGFloat
    private let tabSpacing: CGFloat = 2
    private var tabs: [TabStripCell<Item>] = []

    init(horizontalInset: CGFloat) {
        self.horizontalInset = horizontalInset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    func setTabs(_ tabs: [TabStripCell<Item>]) {
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
            tab.frame = NSRect(x: x, y: max(1, (height - tabHeight) / 2), width: width, height: tabHeight)
            x += width + tabSpacing
        }
        let contentWidth = max(viewportWidth, x + horizontalInset - tabSpacing)
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
    }
}

@MainActor
private final class TabStripCell<Item: TabStripItem>: NSView {
    var onSelect: ((Item.ID) -> Void)?
    var onClose: ((Item.ID) -> Void)?

    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let agentChangeIndicator = NSImageView()
    private let dirtyIndicator = NSImageView()
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private(set) var preferredWidth: CGFloat = 110
    private var configuration: TabStripConfiguration<Item>?
    private var item: Item?
    private var selected = false
    private var hovering = false
    private var showsDirtyIndicator = false
    private var showsAgentIndicator = false
    private var trackingAreaToken: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 12)
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.imagePosition = .imageLeading
        titleButton.imageScaling = .scaleProportionallyDown
        titleButton.alignment = .left
        titleButton.target = self
        titleButton.action = #selector(selectTab)
        addSubview(titleButton)

        agentChangeIndicator.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Modified by approved agent change")
        agentChangeIndicator.contentTintColor = .controlAccentColor
        agentChangeIndicator.setAccessibilityLabel("Modified by approved agent change")
        agentChangeIndicator.toolTip = "Modified by an approved agent change"
        agentChangeIndicator.setAccessibilityElement(true)
        agentChangeIndicator.isHidden = true
        addSubview(agentChangeIndicator)

        dirtyIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved changes")
        dirtyIndicator.contentTintColor = .secondaryLabelColor
        dirtyIndicator.setAccessibilityLabel("Unsaved changes")
        dirtyIndicator.toolTip = "Unsaved changes"
        dirtyIndicator.setAccessibilityElement(true)
        dirtyIndicator.isHidden = true
        addSubview(dirtyIndicator)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.isHidden = true
        addSubview(closeButton)

        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingAreaToken { removeTrackingArea(trackingAreaToken) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaToken = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateAffordances() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAffordances() }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 22
        let dirtySize: CGFloat = 8
        let agentSize: CGFloat = 11
        let closeX = bounds.width - closeSize - 3
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        dirtyIndicator.frame = NSRect(
            x: closeButton.frame.midX - dirtySize / 2,
            y: (bounds.height - dirtySize) / 2,
            width: dirtySize,
            height: dirtySize
        )
        agentChangeIndicator.frame = NSRect(
            x: closeButton.frame.minX - agentSize - 4,
            y: (bounds.height - agentSize) / 2,
            width: agentSize,
            height: agentSize
        )
        let titleTrailing = showsAgentIndicator ? agentChangeIndicator.frame.minX - 9 : closeButton.frame.minX - 6
        titleButton.frame = NSRect(x: 6, y: 1, width: max(0, titleTrailing), height: bounds.height - 2)
    }

    func configure(configuration: TabStripConfiguration<Item>, item: Item, selected: Bool) {
        self.configuration = configuration
        self.item = item
        let title = item.title
        let accessories = configuration.accessories(item)
        showsDirtyIndicator = accessories.contains(.dirty)
        showsAgentIndicator = accessories.contains(.agentModified)
        agentChangeIndicator.isHidden = !showsAgentIndicator

        titleButton.title = title
        titleButton.image = configuration.icon(item)
        titleButton.isEnabled = configuration.isSelectable(item)
        titleButton.setAccessibilityLabel(title)
        titleButton.setAccessibilityValue([
            selected ? "Selected" : nil,
            showsDirtyIndicator ? "Unsaved changes" : nil,
            showsAgentIndicator ? "Modified by AI" : nil
        ].compactMap { $0 }.joined(separator: ", "))
        titleButton.toolTip = configuration.tooltip(item)

        closeButton.isEnabled = configuration.isClosable(item)
        closeButton.toolTip = configuration.closeTooltip(item)
        closeButton.setAccessibilityLabel("Close \(title)")

        setAccessibilityLabel(title)
        if let help = configuration.accessibilityHelp(item) { setAccessibilityHelp(help) }
        setAccessibilitySelected(selected)

        let titleWidth = (title as NSString).size(withAttributes: [.font: titleButton.font ?? .systemFont(ofSize: 12)]).width
        preferredWidth = min(configuration.maxWidth, max(configuration.minWidth, ceil(titleWidth) + configuration.chromeWidth))
        self.selected = selected
        updateColors()
        updateAffordances()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = selected ? (configuration?.selectedBackground(effectiveAppearance) ?? .textBackgroundColor) : .clear
            layer?.backgroundColor = background.cgColor
            titleButton.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        }
    }

    private func updateAffordances() {
        closeButton.isHidden = !hovering
        dirtyIndicator.isHidden = !showsDirtyIndicator || hovering
    }

    @objc private func selectTab() { if let item { onSelect?(item.id) } }
    @objc private func closeTab() { if let item { onClose?(item.id) } }
}
