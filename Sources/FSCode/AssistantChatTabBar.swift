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
    struct Item: TabStripItem, Equatable {
        let id: UUID
        let title: String
        let isSelected: Bool
        let canSelect: Bool
        let canClose: Bool
        let closeToolTip: String
    }

    var onSelect: ((UUID) -> Void)? {
        didSet { strip.onSelect = onSelect }
    }
    var onClose: ((UUID) -> Void)? {
        didSet { strip.onClose = onClose }
    }

    private let strip = TabStripView<Item>(configuration: TabStripConfiguration(
        icon: { _ in NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Chat") },
        isSelectable: { $0.canSelect },
        isClosable: { $0.canClose },
        closeTooltip: { $0.closeToolTip },
        minWidth: 108,
        maxWidth: 210,
        chromeWidth: 58,
        horizontalInset: 0,
        accessibilityGroupLabel: "Open chats"
    ))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(items: [Item]) {
        strip.update(items: items, selectedID: items.first(where: \.isSelected)?.id)
    }
}
