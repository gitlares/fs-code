import AppKit

/// Project-local presentation state. Conversations stay owned by
/// `AgentConversationManager`; closing a tab only removes it from this view.
struct AssistantChatTabState: Codable, Equatable {
    var openThreadIDs: [UUID]
    var selectedThreadID: UUID?

    static func reconciled(
        stored: AssistantChatTabState?,
        availableThreadIDs: [UUID],
        selectedThreadID: UUID?
    ) -> AssistantChatTabState {
        let available = Set(availableThreadIDs)
        var seen = Set<UUID>()
        var open = (stored?.openThreadIDs ?? []).filter { available.contains($0) && seen.insert($0).inserted }

        if let selectedThreadID, available.contains(selectedThreadID), !open.contains(selectedThreadID) {
            open.append(selectedThreadID)
        }
        if open.isEmpty, let first = availableThreadIDs.first {
            open = [first]
        }
        return AssistantChatTabState(openThreadIDs: open, selectedThreadID: selectedThreadID)
    }
}

@MainActor
final class AssistantChatTabStore {
    private struct StoredStates: Codable {
        var states: [String: AssistantChatTabState]
    }

    private let defaults: UserDefaults
    private let key: String

    init(projectURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let canonicalPath = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        key = "com.fscode.assistant.open-chat-tabs." + Data(canonicalPath.utf8).base64EncodedString()
    }

    func state(for profileID: UUID) -> AssistantChatTabState? {
        guard let data = defaults.data(forKey: key),
              let states = try? JSONDecoder().decode(StoredStates.self, from: data) else {
            return nil
        }
        return states.states[profileID.uuidString]
    }

    func save(_ state: AssistantChatTabState, for profileID: UUID) {
        var states = decodedStates()
        states[profileID.uuidString] = state
        guard let data = try? JSONEncoder().encode(StoredStates(states: states)) else { return }
        defaults.set(data, forKey: key)
    }

    private func decodedStates() -> [String: AssistantChatTabState] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredStates.self, from: data) else {
            return [:]
        }
        return stored.states
    }
}

@MainActor
final class AssistantChatTabBar: NSView {
    struct Item: Equatable {
        let id: UUID
        let title: String
        let isSelected: Bool
        let canSelect: Bool
        let canClose: Bool
        let closeToolTip: String
    }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let strip = AssistantChatTabStrip()
    private var tabViews: [UUID: AssistantChatTab] = [:]
    private var orderedIDs: [UUID] = []
    private var selectedID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = strip
        addSubview(scrollView)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open chats")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        strip.layoutTabs(viewportWidth: scrollView.contentView.bounds.width, height: scrollView.contentView.bounds.height)
    }

    func update(items: [Item]) {
        let nextSelectedID = items.first(where: \.isSelected)?.id
        let selectionChanged = selectedID != nextSelectedID
        let incoming = Set(items.map(\.id))
        for id in tabViews.keys where !incoming.contains(id) {
            tabViews[id]?.removeFromSuperview()
            tabViews.removeValue(forKey: id)
        }
        let tabs: [AssistantChatTab] = items.map { item in
            let tab = tabViews[item.id] ?? makeTab(id: item.id)
            tab.configure(item)
            tabViews[item.id] = tab
            return tab
        }
        orderedIDs = items.map(\.id)
        selectedID = nextSelectedID
        strip.setTabs(tabs)
        needsLayout = true
        if selectionChanged, let nextSelectedID {
            DispatchQueue.main.async { [weak self] in
                guard let tab = self?.tabViews[nextSelectedID] else { return }
                tab.scrollToVisible(tab.bounds.insetBy(dx: -8, dy: 0))
            }
        }
    }

    private func makeTab(id: UUID) -> AssistantChatTab {
        let tab = AssistantChatTab(id: id)
        tab.onSelect = { [weak self] id in self?.onSelect?(id) }
        tab.onClose = { [weak self] id in self?.onClose?(id) }
        return tab
    }
}

@MainActor
private final class AssistantChatTabStrip: NSView {
    private let inset: CGFloat = 0
    private let spacing: CGFloat = 2
    private var tabs: [AssistantChatTab] = []

    override var isFlipped: Bool { true }

    func setTabs(_ tabs: [AssistantChatTab]) {
        self.tabs = tabs
        subviews.filter { view in !tabs.contains(where: { $0 === view }) }.forEach { $0.removeFromSuperview() }
        for tab in tabs where tab.superview !== self { addSubview(tab) }
        needsLayout = true
    }

    func layoutTabs(viewportWidth: CGFloat, height: CGFloat) {
        var x = inset
        let tabHeight = min(30, max(25, height - 2))
        for tab in tabs {
            tab.frame = NSRect(x: x, y: max(1, (height - tabHeight) / 2), width: tab.preferredWidth, height: tabHeight)
            x += tab.preferredWidth + spacing
        }
        frame = NSRect(x: 0, y: 0, width: max(viewportWidth, x + inset - spacing), height: height)
    }
}

@MainActor
private final class AssistantChatTab: NSView {
    let id: UUID
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private(set) var preferredWidth: CGFloat = 112
    private var isSelected = false

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 12)
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.imagePosition = .imageLeading
        titleButton.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Chat")
        titleButton.imageScaling = .scaleProportionallyDown
        titleButton.target = self
        titleButton.action = #selector(select)
        addSubview(titleButton)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close chat tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel("Close chat tab")
        addSubview(closeButton)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 22
        closeButton.frame = NSRect(x: bounds.width - closeSize - 2, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        titleButton.frame = NSRect(x: 4, y: 1, width: max(0, closeButton.frame.minX - 5), height: bounds.height - 2)
    }

    func configure(_ item: AssistantChatTabBar.Item) {
        titleButton.title = item.title
        titleButton.isEnabled = item.canSelect
        titleButton.setAccessibilityLabel(item.title)
        titleButton.setAccessibilityValue(item.isSelected ? "Selected" : nil)
        titleButton.toolTip = item.title
        closeButton.isEnabled = item.canClose
        closeButton.toolTip = item.closeToolTip
        closeButton.setAccessibilityLabel("Close \(item.title)")
        setAccessibilityLabel(item.title)
        setAccessibilitySelected(item.isSelected)
        isSelected = item.isSelected
        let textWidth = (item.title as NSString).size(withAttributes: [.font: titleButton.font ?? .systemFont(ofSize: 12)]).width
        preferredWidth = min(210, max(108, ceil(textWidth) + 58))
        updateColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NSColor.selectedControlColor.withAlphaComponent(0.16) : .clear).cgColor
            titleButton.contentTintColor = .labelColor
            closeButton.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func select() { onSelect?(id) }
    @objc private func close() { onClose?(id) }
}
