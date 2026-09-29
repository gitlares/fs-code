import AppKit

/// Live-filtering "@file" popup for the chat composer. Unlike the "/" command
/// menu (a plain NSMenu, which can't filter while the user keeps typing because
/// its tracking loop owns the event stream), this needs its own lightweight
/// floating list so the composer stays editable while the list narrows.
@MainActor
final class ChatMentionPalette: NSView {
    struct Item {
        let relativePath: String
        let action: () -> Void
    }

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var rows: [ChatMentionRow] = []
    private(set) var items: [Item] = []
    private(set) var highlightedIndex = 0

    var isVisible: Bool { !isHidden }

    var preferredHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        return min(CGFloat(items.count) * 26 + 8, 200)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.small
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(items: [Item]) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        highlightedIndex = 0
        rebuildRows()
        isHidden = false
    }

    func hide() {
        guard !isHidden || !items.isEmpty else { return }
        isHidden = true
        items = []
        rows.forEach { $0.removeFromSuperview() }
        rows = []
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
        updateHighlight()
        if rows.indices.contains(highlightedIndex) {
            rows[highlightedIndex].scrollToVisible(rows[highlightedIndex].bounds)
        }
    }

    func selectHighlighted() {
        guard items.indices.contains(highlightedIndex) else { return }
        items[highlightedIndex].action()
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = ChatMentionRow(path: item.relativePath)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.onClick = { [weak self] in
                guard let self else { return }
                self.highlightedIndex = index
                self.updateHighlight()
                item.action()
            }
            stack.addArrangedSubview(row)
            return row
        }
        updateHighlight()
    }

    private func updateHighlight() {
        for (index, row) in rows.enumerated() { row.isHighlighted = index == highlightedIndex }
    }
}

@MainActor
final class ChatMentionRow: NSView {
    var onClick: (() -> Void)?
    var isHighlighted = false { didSet { updateAppearance() } }

    private let background = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(path: String) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])

        iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = path
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
        setAccessibilityLabel(path)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func updateAppearance() {
        background.layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
    }
}

/// Caches the project's file list in memory so filtering while typing "@query"
/// doesn't re-walk the disk on every keystroke.
@MainActor
final class ChatMentionFileIndex {
    private let projectURL: URL
    private var cachedFiles: [String]?
    private var loadTask: Task<[String], Never>?

    init(projectURL: URL) { self.projectURL = projectURL }

    func files() async -> [String] {
        if let cachedFiles { return cachedFiles }
        if let loadTask { return await loadTask.value }
        let root = projectURL
        let task = Task.detached(priority: .userInitiated) { () -> [String] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            var files: [String] = []
            var visited = 0
            while visited < 5_000, files.count < 500, let url = enumerator.nextObject() as? URL {
                visited += 1
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                files.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
            return files.sorted()
        }
        loadTask = task
        let result = await task.value
        cachedFiles = result
        loadTask = nil
        return result
    }

    /// Case-insensitive substring match first, falling back to an in-order
    /// subsequence match (so "acv" still finds "AssistantChatView.swift").
    static func filter(_ files: [String], query: String) -> [String] {
        guard !query.isEmpty else { return files }
        let lowerQuery = query.lowercased()
        var substringMatches: [String] = []
        var subsequenceMatches: [String] = []
        for file in files {
            let lowerFile = file.lowercased()
            if lowerFile.contains(lowerQuery) {
                substringMatches.append(file)
            } else if isSubsequence(lowerQuery, of: lowerFile) {
                subsequenceMatches.append(file)
            }
        }
        return substringMatches + subsequenceMatches
    }

    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        var textIterator = text.makeIterator()
        for character in query {
            var found = false
            while let candidate = textIterator.next() {
                if candidate == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
