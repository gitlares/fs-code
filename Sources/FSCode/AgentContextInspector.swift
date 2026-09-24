import AppKit
import AgentContextCore

private final class AgentContextInspectorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Read-only, selectable inspection of the exact resolved context for one file.
@MainActor
final class AgentContextInspector: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onOpenSource: ((URL) -> Void)?
    var onShowInAgentContext: ((UUID) -> Void)?

    private let resolution: ContextResolution
    private let fileURL: URL
    private let panel: AgentContextInspectorPanel
    private let table = NSTableView()
    private let sourceScroll = NSScrollView()
    private let mode = NSSegmentedControl(labels: ["Selected Source", "Consolidated"], trackingMode: .selectOne, target: nil, action: nil)
    private let provenance = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView(usingTextLayoutManager: true)
    private let diagnostics = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open Source", target: nil, action: nil)
    private let showButton = NSButton(title: "Show in Agent Context", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(resolution: ContextResolution, fileURL: URL) {
        self.resolution = resolution
        self.fileURL = fileURL
        panel = AgentContextInspectorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Effective Agent Context")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let file = NSTextField(labelWithString: fileURL.path)
        file.font = .systemFont(ofSize: 11)
        file.textColor = .secondaryLabelColor
        file.lineBreakMode = .byTruncatingMiddle
        file.setAccessibilityLabel("Inspected file")

        let summary = NSTextField(labelWithString: summaryText)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = resolution.canSend ? .secondaryLabelColor : .systemOrange
        summary.setAccessibilityLabel("Context size summary")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Resolved context sources")
        sourceScroll.documentView = table
        sourceScroll.hasVerticalScroller = true
        sourceScroll.scrollerStyle = .overlay
        sourceScroll.autohidesScrollers = true
        sourceScroll.borderType = .bezelBorder

        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Inspected context content")

        provenance.font = .systemFont(ofSize: 11)
        provenance.textColor = .secondaryLabelColor
        provenance.isSelectable = true
        provenance.maximumNumberOfLines = 0

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Exact context text")
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        diagnostics.font = .systemFont(ofSize: 11)
        diagnostics.textColor = resolution.diagnostics.isEmpty ? .secondaryLabelColor : .systemOrange
        diagnostics.maximumNumberOfLines = 2
        diagnostics.lineBreakMode = .byTruncatingTail
        diagnostics.toolTip = resolution.diagnostics.map(\.message).joined(separator: "\n")
        diagnostics.isSelectable = true

        for button in [openButton, showButton, doneButton] { button.bezelStyle = .rounded; button.target = self }
        openButton.action = #selector(openSource)
        showButton.action = #selector(showInAgentContext)
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"

        let right = NSStackView(views: [mode, provenance, textScroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        for view in [mode, provenance, textScroll] { view.translatesAutoresizingMaskIntoConstraints = false }
        provenance.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        textScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sourceScroll)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        let spacer = NSView()
        let buttons = NSStackView(views: [openButton, showButton, spacer, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        for view in [title, file, summary, split, diagnostics, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            file.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            file.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            file.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: file.trailingAnchor),
            summary.topAnchor.constraint(equalTo: file.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: file.trailingAnchor),
            split.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: diagnostics.topAnchor, constant: -8),
            sourceScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            diagnostics.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            diagnostics.trailingAnchor.constraint(equalTo: file.trailingAnchor),
            diagnostics.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: file.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        self.view = root

        if resolution.entries.isEmpty {
            mode.selectedSegment = 1
            table.isEnabled = false
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetail()
    }

    func present(over host: NSWindow) {
        _ = view
        panel.title = "Effective Agent Context"
        panel.onEscape = { [weak self] in self?.dismiss() }
        preferredContentSize = NSSize(width: 760, height: 580)
        panel.contentViewController = self
        // Assigning a content view controller recalculates a window from the
        // controller's fitting size. Restore the intended inspector workspace
        // afterwards so the selectable source text is visible on first open.
        panel.setContentSize(preferredContentSize)
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 600, height: 420)
        panel.standardWindowButton(.closeButton)?.target = self
        panel.standardWindowButton(.closeButton)?.action = #selector(done)
        host.beginSheet(panel)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { resolution.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = resolution.entries[row]
        let identifier = NSUserInterfaceItemIdentifier("resolved-source")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let title = NSTextField(labelWithString: "")
            let subtitle = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            title.lineBreakMode = .byTruncatingTail
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .secondaryLabelColor
            subtitle.identifier = NSUserInterfaceItemIdentifier("subtitle")
            cell.addSubview(title)
            cell.addSubview(subtitle)
            cell.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
            ])
        }
        let order = entry.order.map { "#\($0)" } ?? "Excluded"
        cell.textField?.stringValue = entry.rule.name
        cell.textField?.textColor = entry.state == .active ? .labelColor : .secondaryLabelColor
        let subtitle = cell.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "subtitle" }
        subtitle?.stringValue = "\(order) · \(entry.state.rawValue.capitalized) · P\(entry.rule.priority)"
        cell.toolTip = entry.reason
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if mode.selectedSegment == 0 { updateDetail() }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    @objc private func modeChanged() { updateDetail() }
    @objc private func done() { dismiss() }

    @objc private func openSource() {
        guard let entry = selectedEntry, let url = entry.rule.url else { return }
        dismiss()
        onOpenSource?(url)
    }

    @objc private func showInAgentContext() {
        guard let entry = selectedEntry else { return }
        dismiss()
        onShowInAgentContext?(entry.rule.id)
    }

    private var selectedEntry: ContextResolutionEntry? {
        guard resolution.entries.indices.contains(table.selectedRow) else { return nil }
        return resolution.entries[table.selectedRow]
    }

    private var summaryText: String {
        let active = resolution.entries.filter { $0.state == .active }.count
        let friendly = ByteCountFormatter.string(fromByteCount: Int64(resolution.utf8ByteCount), countStyle: .file)
        return "\(active) active rule\(active == 1 ? "" : "s") · \(resolution.utf8ByteCount) UTF-8 bytes (\(friendly)) · about \(resolution.approximateTokenCount) tokens"
    }

    private func updateDetail() {
        let consolidated = mode.selectedSegment == 1
        table.isEnabled = !consolidated
        openButton.isEnabled = !consolidated && selectedEntry?.rule.url != nil
        showButton.isEnabled = !consolidated && selectedEntry != nil
        if consolidated {
            provenance.stringValue = "Exact consolidated text produced by the shared resolver."
            textView.string = resolution.consolidatedText
        } else if let entry = selectedEntry {
            provenance.stringValue = provenanceText(for: entry)
            textView.string = entry.rule.content
        } else {
            provenance.stringValue = "No context sources apply to this file."
            textView.string = ""
        }
        if resolution.diagnostics.isEmpty {
            diagnostics.stringValue = resolution.canSend ? "No resolution diagnostics." : "The context cannot be used until its diagnostics are resolved."
        } else {
            diagnostics.stringValue = resolution.diagnostics.map { "\($0.kind.rawValue.capitalized): \($0.message)" }.joined(separator: "  ·  ")
        }
    }

    private func provenanceText(for entry: ContextResolutionEntry) -> String {
        var lines = [
            "Provider: \(entry.rule.provider.rawValue.capitalized)",
            "Path: \(entry.rule.url?.path ?? entry.rule.target ?? "—")",
            "Scope: \(entry.rule.scope.rawValue.capitalized) · Priority: \(entry.rule.priority)",
            "State: \(entry.state.rawValue.capitalized) · \(entry.reason)"
        ]
        if !entry.matchedPaths.isEmpty { lines.append("Matches: \(entry.matchedPaths.joined(separator: ", "))") }
        if !entry.rule.matchPatterns.isEmpty { lines.append("Patterns: \(entry.rule.matchPatterns.joined(separator: ", "))") }
        if !entry.rule.diagnostics.isEmpty { lines.append("Diagnostics: \(entry.rule.diagnostics.map(\.message).joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }

    private func dismiss() {
        panel.onEscape = nil
        panel.delegate = nil
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
            panel.contentViewController = nil
        } else {
            panel.contentViewController = nil
            panel.close()
        }
    }
}
