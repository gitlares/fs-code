import AppKit
import AgentContextCore
import AgentConnectionCore

/// Native context manager. Its source list is hosted by the project sidebar and
/// its detail editor is shown in the centre pane.
@MainActor
final class AgentContextView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    typealias CreateHandler = (String, ContextScope, String?, Int, String) async throws -> ContextRule
    typealias UpdateHandler = (UUID, String, String, ContextScope, String?, Int, Bool, String) async throws -> ContextRule

    var onCreate: CreateHandler?
    var onUpdate: UpdateHandler?
    var onRemove: ((UUID) async throws -> Void)?
    var onSetActivation: ((UUID, Bool) async throws -> ContextRule)?
    var onOpenSource: ((URL) -> Void)?
    var onRefresh: (() -> Void)?

    private final class Node: NSObject {
        let title: String
        let rule: ContextRule?
        var children: [Node]
        init(_ title: String, rule: ContextRule? = nil, children: [Node] = []) {
            self.title = title
            self.rule = rule
            self.children = children
        }
    }

    private enum LeaveDecision { case save, discard, cancel }

    let sidebarView = NSView()
    private let outline = NSOutlineView()
    private let tree = NSScrollView()
    private let newButton = NSButton(title: "New Context", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let promptsButton = NSButton(title: "System Prompts", target: nil, action: nil)
    private let promptEditor = SystemPromptEditorView()
    private var showingPrompts = false
    private let detailScroll = NSScrollView()
    private let detail = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Agent Context")
    private let nameField = NSTextField()
    private let scopePopup = NSPopUpButton()
    private let targetField = NSTextField()
    private let priorityField = NSTextField()
    private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let metadata = NSTextField(wrappingLabelWithString: "")
    private let source = NSTextView(usingTextLayoutManager: true)
    private let sourceScroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "Select a context source.")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Source", target: nil, action: nil)
    private let activateButton = NSButton(title: "Enable", target: nil, action: nil)
    private let form = NSGridView(views: [])
    private let instructionsLabel = NSTextField(labelWithString: "Instructions")

    private var roots: [Node] = []
    private var rulesByID: [UUID: ContextRule] = [:]
    private var selectedRule: ContextRule?
    private var isDraft = false
    private var isDirty = false
    private var isSaving = false
    private var restoringSelection = false
    private var externallyChanged = false

    var canSave: Bool { showingPrompts ? promptEditor.canSave : (!isSaving && (isDraft || (selectedRule?.origin == .fsCode && isDirty))) }
    var canLeave: Bool { showingPrompts ? promptEditor.canSave == false : (!isDirty && !isSaving) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        configureSidebar()
        configureEditor()
        showEmptyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configureSystemPrompts(projectURL: URL) { promptEditor.configure(projectURL: projectURL) }

    private func configureSidebar() {
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent-context"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 34
        outline.indentationPerLevel = 12
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(openSelectedSource)
        outline.menu = makeContextMenu()
        outline.setAccessibilityLabel("Agent Context sources")
        tree.documentView = outline
        tree.hasVerticalScroller = true
        tree.scrollerStyle = .overlay
        tree.autohidesScrollers = true
        tree.drawsBackground = false
        tree.borderType = .noBorder

        newButton.target = self
        newButton.action = #selector(requestNewRule)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        promptsButton.target = self
        promptsButton.action = #selector(showSystemPrompts)
        for button in [newButton, refreshButton, promptsButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let actions = NSStackView(views: [newButton, refreshButton, promptsButton])
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 6
        for view in [tree, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebarView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            actions.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 4),
            tree.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6),
            tree.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor)
        ])
    }

    private func configureEditor() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        scopePopup.addItems(withTitles: ["Global", "Project", "Folder", "Pattern", "File"])
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        nameField.placeholderString = "Untitled context"
        targetField.placeholderString = "Folder, file, or glob pattern"
        priorityField.placeholderString = "0"
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        targetField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        priorityField.formatter = formatter
        for field in [nameField, targetField, priorityField] { field.delegate = self }
        enabled.target = self
        enabled.action = #selector(enabledChanged)

        form.addRow(with: [NSTextField(labelWithString: "Name"), nameField])
        form.addRow(with: [NSTextField(labelWithString: "Scope"), scopePopup])
        form.addRow(with: [NSTextField(labelWithString: "Target"), targetField])
        form.addRow(with: [NSTextField(labelWithString: "Priority"), priorityField])
        form.addRow(with: [NSTextField(labelWithString: "State"), enabled])
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).width = 72
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        metadata.font = .systemFont(ofSize: 12)
        metadata.textColor = .secondaryLabelColor
        metadata.isSelectable = true
        metadata.maximumNumberOfLines = 0

        source.isRichText = false
        source.delegate = self
        source.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        source.textColor = .textColor
        source.backgroundColor = .textBackgroundColor
        source.textContainerInset = NSSize(width: 10, height: 10)
        source.isVerticallyResizable = true
        source.isHorizontallyResizable = false
        source.textContainer?.widthTracksTextView = true
        source.setAccessibilityLabel("Context instructions")
        sourceScroll.documentView = source
        sourceScroll.hasVerticalScroller = true
        sourceScroll.scrollerStyle = .overlay
        sourceScroll.autohidesScrollers = true
        sourceScroll.borderType = .bezelBorder
        let editorHeight = sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190)
        editorHeight.priority = .defaultHigh
        editorHeight.isActive = true

        for button in [saveButton, deleteButton, openButton, activateButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        saveButton.action = #selector(save)
        deleteButton.action = #selector(requestDelete)
        openButton.action = #selector(openSelectedSource)
        activateButton.action = #selector(toggleActivation)
        let actions = NSStackView(views: [saveButton, deleteButton, activateButton, openButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0
        status.isSelectable = true

        detail.orientation = .vertical
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        for view in [titleLabel, form, metadata, instructionsLabel, sourceScroll, status, actions] {
            detail.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [form, metadata, sourceScroll, status] {
            let width = view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -36)
            // NSStackView installs required zero-size constraints for hidden
            // arranged views. Keep content sizing below that priority so inactive
            // details cannot constrain the workspace split view.
            width.priority = .defaultHigh
            width.isActive = true
        }

        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.scrollerStyle = .overlay
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailScroll)
        promptEditor.translatesAutoresizingMaskIntoConstraints = false
        promptEditor.isHidden = true
        addSubview(promptEditor)
        NSLayoutConstraint.activate([
            detailScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            promptEditor.leadingAnchor.constraint(equalTo: leadingAnchor),
            promptEditor.trailingAnchor.constraint(equalTo: trailingAnchor),
            promptEditor.topAnchor.constraint(equalTo: topAnchor),
            promptEditor.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detail.bottomAnchor.constraint(greaterThanOrEqualTo: detailScroll.contentView.bottomAnchor)
        ])
    }

    func apply(_ snapshot: ContextCatalogSnapshot) {
        let incoming = Dictionary(uniqueKeysWithValues: snapshot.rules.map { ($0.id, $0) })
        rulesByID = incoming
        let groups: [(String, (ContextRule) -> Bool)] = [
            ("Global FS Code", { $0.origin == .fsCode && $0.scope == .global }),
            ("Project", { $0.origin == .fsCode && $0.scope == .project }),
            ("Folders", { $0.origin == .fsCode && $0.scope == .folder }),
            ("Files", { $0.origin == .fsCode && ($0.scope == .file || $0.scope == .glob) }),
            ("External", { $0.origin == .external })
        ]
        roots = groups.map { title, filter in
            let children = snapshot.rules.filter(filter).sorted(by: Self.ruleSort).map { Node($0.name, rule: $0) }
            return Node(title, children: children)
        }
        reloadOutline()

        guard let selectedRule else { return }
        guard let refreshed = incoming[selectedRule.id] else {
            if isDirty {
                externallyChanged = true
                status.stringValue = "This context was removed on disk. Your draft is preserved; copy it into a new context before leaving."
                status.textColor = .systemOrange
            } else {
                showEmptyState(message: "The selected context no longer exists.")
            }
            return
        }
        selectOutlineRule(id: selectedRule.id)
        if isDirty {
            if refreshed != selectedRule {
                externallyChanged = true
                status.stringValue = "This context changed on disk. Your draft is preserved. Saving will check for a conflict."
                status.textColor = .systemOrange
            }
        } else {
            display(refreshed)
        }
    }

    func showCatalogError(_ error: Error) {
        status.stringValue = "Couldn’t refresh context sources: \(error.localizedDescription)"
        status.textColor = .systemRed
    }

    func selectRule(id: UUID) {
        guard let rule = rulesByID[id] else { return }
        Task { [weak self] in
            guard let self, await self.prepareToLeave(), await self.leavePromptsIfNeeded() else { return }
            self.showingPrompts = false; self.promptEditor.isHidden = true; self.detailScroll.isHidden = false
            self.selectOutlineRule(id: id)
            self.display(rule)
        }
    }

    func prepareToLeave() async -> Bool {
        if showingPrompts { return await promptEditor.prepareToLeave() }
        guard !isSaving else { return false }
        guard isDirty else { return true }
        switch await askToSaveDraft() {
        case .cancel: return false
        case .discard:
            isDirty = false
            externallyChanged = false
            if let selectedRule, let current = rulesByID[selectedRule.id] { display(current) }
            return true
        case .save: return await performSave()
        }
    }

    func saveCurrent() {
        if showingPrompts { promptEditor.saveCurrent() }
        else { Task { [weak self] in _ = await self?.performSave() } }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.rule == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.rule == nil { return groupCell(node.title, in: outlineView) }
        guard let rule = node.rule else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("context-rule")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let title = NSTextField(labelWithString: "")
            let caption = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            caption.translatesAutoresizingMaskIntoConstraints = false
            title.lineBreakMode = .byTruncatingTail
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            caption.lineBreakMode = .byTruncatingTail
            caption.identifier = NSUserInterfaceItemIdentifier("caption")
            cell.addSubview(title)
            cell.addSubview(caption)
            cell.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
                caption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                caption.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                caption.topAnchor.constraint(equalTo: title.bottomAnchor),
                caption.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2)
            ])
        }
        cell.textField?.stringValue = rule.name
        let caption = cell.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "caption" }
        caption?.stringValue = "\(rule.provider.rawValue.capitalized) · \(catalogState(for: rule)) · P\(rule.priority)"
        cell.textField?.textColor = rule.enabled ? .labelColor : .secondaryLabelColor
        cell.toolTip = rule.url?.path ?? rule.target
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection,
              let node = outline.item(atRow: outline.selectedRow) as? Node,
              let next = node.rule,
              next.id != selectedRule?.id else { return }
        guard !isSaving else { restoreCurrentSelection(); return }
        if isDirty {
            restoreCurrentSelection()
            Task { [weak self] in
                guard let self, await self.prepareToLeave() else { return }
                self.selectOutlineRule(id: next.id)
                self.display(next)
            }
        } else {
            display(next)
        }
    }

    func controlTextDidChange(_ obj: Notification) { markDirty() }
    func textDidChange(_ notification: Notification) { markDirty() }

    @objc private func scopeChanged() {
        if scopeForPopup() == .global || scopeForPopup() == .project { targetField.stringValue = "" }
        updateTargetAvailability()
        markDirty()
    }
    @objc private func enabledChanged() { markDirty() }
    @objc private func refresh() { onRefresh?() }
    @objc private func save() { saveCurrent() }

    @objc private func requestNewRule() {
        Task { [weak self] in
            guard let self, await self.prepareToLeave() else { return }
            self.outline.deselectAll(nil)
            self.showNewDraft()
        }
    }

    @objc private func showSystemPrompts() {
        Task { [weak self] in
            guard let self, await self.prepareToLeave(), await self.leavePromptsIfNeeded() else { return }
            self.showingPrompts = true
            self.detailScroll.isHidden = true
            self.promptEditor.isHidden = false
        }
    }

    private func leavePromptsIfNeeded() async -> Bool {
        guard showingPrompts else { return true }
        return await promptEditor.prepareToLeave()
    }

    @objc private func requestDelete() {
        guard let rule = selectedRule, rule.origin == .fsCode, !isSaving, window?.attachedSheet == nil else { return }
        Task { [weak self] in
            guard let self, await self.confirmDelete(rule), let remove = self.onRemove else { return }
            self.setBusy(true, message: "Deleting…")
            do {
                try await remove(rule.id)
                self.isDirty = false
                self.selectedRule = nil
                self.showEmptyState(message: "Context deleted.")
                self.onRefresh?()
            } catch { self.showOperationError(error) }
            self.setBusy(false)
        }
    }

    @objc private func toggleActivation() {
        guard let rule = selectedRule, rule.origin == .external, let handler = onSetActivation, !isSaving else { return }
        Task { [weak self] in
            guard let self else { return }
            self.setBusy(true, message: rule.enabled ? "Ignoring source…" : "Enabling source…")
            do {
                let saved = try await handler(rule.id, !rule.enabled)
                self.display(saved)
                self.onRefresh?()
            } catch { self.showOperationError(error) }
            self.setBusy(false)
        }
    }

    @objc private func openSelectedSource() {
        guard !isSaving, let url = selectedRule?.url else { return }
        onOpenSource?(url)
    }

    private func performSave() async -> Bool {
        guard !isSaving else { return false }
        guard !externallyChanged else {
            return validationFailure("This context changed on disk. Copy this draft into a new context or discard it and reload before saving.", focus: source)
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return validationFailure("Enter a name before saving.", focus: nameField) }
        let scope = scopeForPopup()
        let rawTarget = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = rawTarget.isEmpty ? nil : rawTarget
        if scope != .global && scope != .project && target == nil {
            return validationFailure("Enter a target for this scope.", focus: targetField)
        }
        guard let priority = Int(priorityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return validationFailure("Priority must be a whole number.", focus: priorityField)
        }
        setBusy(true, message: "Saving…")
        defer { setBusy(false) }
        do {
            let saved: ContextRule
            if let rule = selectedRule {
                guard rule.origin == .fsCode, let update = onUpdate else { return false }
                saved = try await update(rule.id, rule.hash, name, scope, target, priority, enabled.state == .on, source.string)
            } else {
                guard let create = onCreate else { return false }
                saved = try await create(name, scope, target, priority, source.string)
            }
            display(saved)
            selectOutlineRule(id: saved.id)
            onRefresh?()
            return true
        } catch {
            showOperationError(error)
            return false
        }
    }

    private func validationFailure(_ message: String, focus: NSView) -> Bool {
        status.stringValue = message
        status.textColor = .systemRed
        window?.makeFirstResponder(focus)
        return false
    }

    private func display(_ rule: ContextRule) {
        selectedRule = rule
        isDraft = false
        isDirty = false
        externallyChanged = false
        nameField.stringValue = rule.name
        scopePopup.selectItem(at: popupIndex(for: rule.scope))
        targetField.stringValue = rule.target ?? ""
        priorityField.stringValue = String(rule.priority)
        enabled.state = rule.enabled ? .on : .off
        source.string = rule.content
        titleLabel.stringValue = rule.name
        metadata.stringValue = metadataText(for: rule)
        status.stringValue = rule.diagnostics.isEmpty ? statusText(for: rule) : rule.diagnostics.map(\.message).joined(separator: "\n")
        status.textColor = rule.diagnostics.isEmpty ? .secondaryLabelColor : .systemOrange
        updateForm()
    }

    private func showNewDraft() {
        selectedRule = nil
        isDraft = true
        isDirty = false
        externallyChanged = false
        nameField.stringValue = ""
        scopePopup.selectItem(at: 1)
        targetField.stringValue = ""
        priorityField.stringValue = "0"
        enabled.state = .on
        source.string = ""
        titleLabel.stringValue = "New Context"
        metadata.stringValue = ""
        status.stringValue = "The context will be stored locally after you save."
        status.textColor = .secondaryLabelColor
        updateForm()
        window?.makeFirstResponder(nameField)
    }

    private func showEmptyState(message: String = "Select a context source or create a new one.") {
        selectedRule = nil
        isDraft = false
        isDirty = false
        externallyChanged = false
        outline.deselectAll(nil)
        titleLabel.stringValue = "Agent Context"
        nameField.stringValue = ""
        targetField.stringValue = ""
        priorityField.stringValue = ""
        source.string = ""
        metadata.stringValue = ""
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        updateForm()
    }

    private func updateForm() {
        let external = selectedRule?.origin == .external
        let hasSelection = selectedRule != nil || isDraft
        form.isHidden = external || !hasSelection
        instructionsLabel.isHidden = !hasSelection
        sourceScroll.isHidden = !hasSelection
        metadata.isHidden = !hasSelection || isDraft
        source.isEditable = hasSelection && !external && !isSaving
        source.isSelectable = hasSelection
        enabled.isHidden = external
        saveButton.isHidden = external || !hasSelection
        saveButton.isEnabled = !isSaving
        deleteButton.isHidden = external || isDraft || selectedRule == nil
        deleteButton.isEnabled = !isSaving
        openButton.isHidden = selectedRule?.url == nil
        openButton.isEnabled = !isSaving
        activateButton.isHidden = !external
        activateButton.isEnabled = !isSaving && selectedRule?.applicability != .unsupported
        activateButton.title = selectedRule?.enabled == true ? "Ignore" : "Enable"
        for control in [nameField, scopePopup, targetField, priorityField, enabled] {
            control.isEnabled = hasSelection && !external && !isSaving
        }
        if isDraft { enabled.isEnabled = false }
        updateTargetAvailability()
        newButton.isEnabled = !isSaving
        refreshButton.isEnabled = !isSaving
    }

    private func updateTargetAvailability() {
        guard !isSaving, selectedRule?.origin != .external, selectedRule != nil || isDraft else {
            targetField.isEnabled = false
            return
        }
        targetField.isEnabled = scopeForPopup() != .global && scopeForPopup() != .project
    }

    private func markDirty() {
        guard !isSaving, selectedRule?.origin != .external, selectedRule != nil || isDraft else { return }
        isDirty = true
        status.stringValue = externallyChanged ? "Unsaved changes · source also changed on disk" : "Unsaved changes"
        status.textColor = externallyChanged ? .systemOrange : .secondaryLabelColor
    }

    private func setBusy(_ busy: Bool, message: String? = nil) {
        isSaving = busy
        if let message {
            status.stringValue = message
            status.textColor = .secondaryLabelColor
        }
        updateForm()
    }

    private func showOperationError(_ error: Error) {
        status.stringValue = error.localizedDescription
        status.textColor = .systemRed
    }

    private func askToSaveDraft() async -> LeaveDecision {
        guard let hostWindow = window else { return .cancel }
        let alert = NSAlert()
        alert.messageText = "Save changes to this context?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: hostWindow) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .save)
                case .alertSecondButtonReturn: continuation.resume(returning: .discard)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func confirmDelete(_ rule: ContextRule) async -> Bool {
        guard let hostWindow = window else { return false }
        let alert = NSAlert()
        alert.messageText = "Delete “\(rule.name)”?"
        alert.informativeText = "This permanently deletes its Markdown file and removes its metadata from FS Code."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: hostWindow) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func metadataText(for rule: ContextRule) -> String {
        var parts = ["Provider: \(rule.provider.rawValue.capitalized)", "Path: \(rule.url?.path ?? "—")"]
        guard rule.origin == .external else { return parts.joined(separator: "\n") }
        parts.append(contentsOf: [
            "Scope: \(rule.scope.rawValue.capitalized)",
            "State: \(catalogState(for: rule).capitalized)",
            "Priority: \(rule.priority)"
        ])
        if !rule.matchPatterns.isEmpty { parts.append("Patterns: \(rule.matchPatterns.joined(separator: ", "))") }
        if let reason = rule.applicabilityReason, !reason.isEmpty { parts.append("Reason: \(reason)") }
        return parts.joined(separator: "\n")
    }

    private func statusText(for rule: ContextRule) -> String {
        if rule.origin == .external {
            if rule.applicability == .unsupported { return rule.applicabilityReason ?? "This source type is unsupported." }
            return rule.enabled ? "This external source contributes to matching files." : "Enable this external source to include it in effective context."
        }
        return "FS Code context · \(rule.enabled ? "Enabled" : "Disabled")"
    }

    private func catalogState(for rule: ContextRule) -> String {
        if rule.diagnostics.contains(where: { $0.kind == .conflict }) { return "conflict" }
        if rule.diagnostics.contains(where: { $0.kind == .stale }) { return "stale" }
        if rule.applicability == .replaced { return "replaced" }
        if rule.applicability == .unsupported { return "unsupported" }
        if rule.applicability == .manual { return rule.enabled ? "active" : "manual" }
        if rule.applicability == .unknown { return rule.enabled ? "active" : "unknown" }
        return rule.enabled ? "active" : "ignored"
    }

    private func groupCell(_ title: String, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("context-group")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = title
        return cell
    }

    private func reloadOutline() {
        restoringSelection = true
        outline.reloadData()
        roots.forEach(outline.expandItem)
        if let id = selectedRule?.id { selectOutlineRule(id: id) }
        restoringSelection = false
    }

    private func restoreCurrentSelection() {
        restoringSelection = true
        if let id = selectedRule?.id { selectOutlineRule(id: id) }
        else { outline.deselectAll(nil) }
        restoringSelection = false
    }

    private func selectOutlineRule(id: UUID) {
        guard let row = row(for: id) else { return }
        restoringSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        restoringSelection = false
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let new = menu.addItem(withTitle: "New Context", action: #selector(requestNewRule), keyEquivalent: "")
        new.target = self
        let reload = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "")
        reload.target = self
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Source", action: #selector(openSelectedSource), keyEquivalent: "")
        open.target = self
        return menu
    }

    private func scopeForPopup() -> ContextScope {
        let scopes: [ContextScope] = [.global, .project, .folder, .glob, .file]
        guard scopes.indices.contains(scopePopup.indexOfSelectedItem) else { return .project }
        return scopes[scopePopup.indexOfSelectedItem]
    }

    private func popupIndex(for scope: ContextScope) -> Int {
        [.global, .project, .folder, .glob, .file].firstIndex(of: scope) ?? 1
    }

    private func row(for id: UUID) -> Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? Node)?.rule?.id == id }
    }

    private static func ruleSort(_ lhs: ContextRule, _ rhs: ContextRule) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
