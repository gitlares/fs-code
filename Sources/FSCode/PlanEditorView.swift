import AppKit
import AgentConnectionCore

@MainActor
final class PlanEditorView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var onOpenFile: ((String) -> Void)?
    var onRun: ((String) async throws -> Void)?
    let sidebarView = NSView()

    private let store: ProjectPlanStore?
    private let projectURL: URL
    private let outline = NSOutlineView()
    private let list = NSScrollView()
    private let titleField = NSTextField()
    private let markdown = NSTextView(usingTextLayoutManager: true)
    private let editorScroll = NSScrollView()
    private let preview = MarkdownPreviewView(frame: .zero)
    private let contentHost = NSView()
    private let modeControl = NSSegmentedControl(
        labels: ["Preview", "Code"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let status = NSTextField(wrappingLabelWithString: "Select a plan.")
    private let references = NSStackView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let approveButton = NSButton(title: "Approve", target: nil, action: nil)
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private var plans: [ProjectPlanMetadata] = []
    private var selected: ProjectPlan?
    private var isSaving = false
    private var isRunning = false
    private var restoringSelection = false
    private var isApproved = false
    private var showingPreview = true

    var canSave: Bool { selected != nil && isDirty && !isSaving && !isRunning }

    init(projectURL: URL) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        store = try? ProjectPlanStore(projectURL: projectURL)
        super.init(frame: .zero)
        configure()
        if store == nil { status.stringValue = "Plan storage is unavailable."; status.textColor = .systemRed } else { reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload() {
        guard !isDirty else { return }
        guard let store else { return }
        do {
            plans = try store.list()
            outline.reloadData()
            if let id = selected?.metadata.planID { select(id: id) }
        } catch {
            status.stringValue = "Couldn’t load plans: \(error.localizedDescription)"
            status.textColor = .systemRed
        }
    }

    func prepareToLeave() async -> Bool {
        guard !isSaving else { return false }
        return await resolveDirtyPlan()
    }

    private var isDirty: Bool {
        guard let selected else { return false }
        return titleField.stringValue != selected.metadata.title || markdown.string != selected.markdown
    }

    private func configure() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plans"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 34
        outline.delegate = self
        outline.dataSource = self
        list.documentView = outline
        list.hasVerticalScroller = true
        list.scrollerStyle = .overlay
        list.drawsBackground = false

        titleField.isEditable = false
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityLabel("Plan title")
        markdown.isRichText = false
        markdown.delegate = self
        markdown.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        markdown.isVerticallyResizable = true
        markdown.isHorizontallyResizable = false
        markdown.textContainer?.widthTracksTextView = true
        markdown.setAccessibilityLabel("Plan Markdown")
        editorScroll.documentView = markdown
        editorScroll.hasVerticalScroller = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.borderType = .bezelBorder
        editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(changePresentation(_:))
        modeControl.setAccessibilityLabel("Plan presentation")

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        for view in [editorScroll, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])
        }
        editorScroll.isHidden = true

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleField, titleSpacer, modeControl])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        for button in [saveButton, approveButton, runButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        saveButton.action = #selector(save)
        approveButton.action = #selector(approve)
        runButton.action = #selector(run)
        let actions = NSStackView(views: [saveButton, approveButton, runButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        references.orientation = .vertical
        references.alignment = .leading
        references.spacing = 4
        let detail = NSStackView(views: [header, references, contentHost, status, actions])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(list)
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)
        for view in [header, contentHost, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -36).isActive = true
        }
        contentHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor), list.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            list.topAnchor.constraint(equalTo: sidebarView.topAnchor), list.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor), detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor), detail.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateRunAction()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? plans.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { plans[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let plan = item as? ProjectPlanMetadata else { return nil }
        let id = NSUserInterfaceItemIdentifier("plan")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = "\(plan.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) · \(plan.title)"
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }
        guard let item = outline.item(atRow: outline.selectedRow) as? ProjectPlanMetadata else { return }
        guard item.planID != selected?.metadata.planID else { return }
        restoreSelection()
        Task { [weak self] in
            guard let self, await self.resolveDirtyPlan() else { return }
            self.select(id: item.planID)
        }
    }

    private func select(id: String) {
        guard let store else { return }
        do {
            let isNewSelection = selected?.metadata.planID != id
            let plan = try store.read(planID: id)
            selected = plan
            isApproved = false
            titleField.stringValue = plan.metadata.title
            markdown.string = plan.markdown
            setShowingPreview(isNewSelection ? true : showingPreview)
            restoreSelection()
            configureReferences(markdown: plan.markdown)
            status.stringValue = "Revision \(plan.metadata.revision) · \(plan.metadata.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)"
            status.textColor = .secondaryLabelColor
            approveButton.isEnabled = plan.metadata.status != .inProgress
            runButton.isEnabled = false
            Task { [weak self] in
                guard let self, let store = self.store else { return }
                guard self.selected?.metadata.planID == plan.metadata.planID else { return }
                self.isApproved = (try? store.isApproved(planID: plan.metadata.planID)) == true
                self.updateRunAction()
            }
        } catch { status.stringValue = "Couldn’t open this plan: \(error.localizedDescription)"; status.textColor = .systemRed }
    }
    func textDidChange(_ notification: Notification) {
        if let title = Self.planTitle(from: markdown.string) {
            titleField.stringValue = title
        }
        updateRunAction()
    }

    @objc private func changePresentation(_ sender: NSSegmentedControl) {
        setShowingPreview(sender.selectedSegment == 0)
    }

    private func setShowingPreview(_ previewIsVisible: Bool) {
        showingPreview = previewIsVisible
        modeControl.selectedSegment = previewIsVisible ? 0 : 1
        preview.isHidden = !previewIsVisible
        editorScroll.isHidden = previewIsVisible
        if previewIsVisible {
            window?.makeFirstResponder(nil)
            preview.showMarkdown(source: Self.previewMarkdown(from: markdown.string))
        } else {
            window?.makeFirstResponder(markdown)
        }
    }

    private func updateRunAction() {
        let approvalIsCurrent = isApproved && !isDirty
        let canEdit = selected != nil && store != nil && !isSaving && !isRunning
        let canRun = canEdit && onRun != nil
        let canApprove = selected?.metadata.status == .draft

        runButton.title = approvalIsCurrent ? "Run" : "Approve and Run"
        runButton.isEnabled = canRun && (approvalIsCurrent || canApprove)
        approveButton.isEnabled = canEdit && canApprove
        saveButton.isEnabled = canEdit && isDirty

        if isDirty {
            status.stringValue = "Unsaved changes · approval required."
            status.textColor = .secondaryLabelColor
        }
    }

    private func resolveDirtyPlan() async -> Bool {
        guard isDirty else { return true }
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes to this plan?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    Task { continuation.resume(returning: await self.saveCurrent()) }
                } else if response == .alertSecondButtonReturn {
                    if let selected = self.selected {
                        self.titleField.stringValue = selected.metadata.title
                        self.markdown.string = selected.markdown
                    }
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func restoreSelection() {
        restoringSelection = true
        if let id = selected?.metadata.planID,
           let row = plans.firstIndex(where: { $0.planID == id }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        restoringSelection = false
    }

    @objc private func save() { saveCurrentFromUserAction() }
    func saveCurrentFromUserAction() { Task { _ = await saveCurrent() } }
    private func saveCurrent() async -> Bool {
        guard let store else { status.stringValue = "Plan storage is unavailable."; return false }
        guard let selected, !isSaving else { return !isSaving }
        guard isDirty else { return true }
        isSaving = true
        updateRunAction()
        defer {
            isSaving = false
            updateRunAction()
        }
        do {
            let body = Self.draftBody(from: markdown.string)
            let saved = try store.saveDraft(
                planID: selected.metadata.planID,
                title: titleField.stringValue,
                format: selected.metadata.format,
                body: body,
                expectedRevision: selected.metadata.revision,
                expectedContentHash: selected.metadata.contentHash
            )
            self.selected = saved
            self.isApproved = false
            markdown.string = saved.markdown
            titleField.stringValue = saved.metadata.title
            status.stringValue = "Saved as draft. Approval was reset."
            status.textColor = .secondaryLabelColor
            reload()
            updateRunAction()
            return true
        } catch { status.stringValue = "Couldn’t save this plan: \(error.localizedDescription)"; status.textColor = .systemRed; return false }
    }
    @objc private func approve() {
        Task { [weak self] in
            guard let self,
                  let store = self.store,
                  await self.saveCurrent(),
                  let selected = self.selected
            else { return }

            do {
                _ = try store.approve(planID: selected.metadata.planID)
                self.isApproved = true
                self.reload()
                self.status.stringValue = "Approved for execution."
                self.status.textColor = .secondaryLabelColor
                self.updateRunAction()
            } catch {
                self.status.stringValue = "Couldn’t approve this plan: \(error.localizedDescription)"
                self.status.textColor = .systemRed
            }
        }
    }
    @objc private func run() {
        Task { [weak self] in
            guard let self, let store = self.store, await self.saveCurrent(), let selected = self.selected, let onRun = self.onRun else { return }
            self.isRunning = true
            self.updateRunAction()
            defer {
                self.isRunning = false
                self.updateRunAction()
            }
            do {
                if !(try store.isApproved(planID: selected.metadata.planID)) {
                    _ = try store.approve(planID: selected.metadata.planID)
                    self.isApproved = true
                    self.updateRunAction()
                }
                try await onRun(selected.metadata.planID)
                self.status.stringValue = "Running plan."
            } catch {
                self.status.stringValue = "Couldn’t run this plan: \(error.localizedDescription)"
                self.status.textColor = .systemRed
            }
        }
    }
    static func draftBody(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---",
              let frontmatterEnd = lines.dropFirst().firstIndex(of: "---") else { return markdown }
        var content = Array(lines.dropFirst(frontmatterEnd + 1))
        while content.first?.isEmpty == true { content.removeFirst() }
        if content.first?.hasPrefix("# ") == true {
            content.removeFirst()
            if content.first?.isEmpty == true { content.removeFirst() }
        }
        return content.joined(separator: "\n")
    }

    static func previewMarkdown(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---",
              let frontmatterEnd = lines.dropFirst().firstIndex(of: "---")
        else { return markdown }
        return lines.dropFirst(frontmatterEnd + 1)
            .drop(while: { $0.isEmpty })
            .joined(separator: "\n")
    }

    private static func planTitle(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---",
              let frontmatterEnd = lines.dropFirst().firstIndex(of: "---")
        else { return nil }
        return lines[1..<frontmatterEnd]
            .first(where: { $0.hasPrefix("title:") })?
            .dropFirst("title:".count)
            .trimmingCharacters(in: .whitespaces)
    }

    private func configureReferences(markdown: String) {
        references.arrangedSubviews.forEach { references.removeArrangedSubview($0); $0.removeFromSuperview() }
        let paths = markdown.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- ", with: "", options: [.anchored]).hasPrefix("Files:") }
            .flatMap { line in line.split(separator: "`").enumerated().compactMap { !$0.offset.isMultiple(of: 2) ? String($0.element) : nil } }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { references.isHidden = true; return }
        references.isHidden = false
        references.addArrangedSubview(NSTextField(labelWithString: "Files:"))
        for path in paths {
            guard let url = verifiedProjectFile(path) else { continue }
            let button = PlanReferenceButton(path: path, url: url)
            button.target = self
            button.action = #selector(openReference(_:))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.toolTip = "Open \(path)"
            references.addArrangedSubview(button)
        }
        references.isHidden = references.arrangedSubviews.count == 1
    }

    private func verifiedProjectFile(_ path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("..") else { return nil }
        let candidate = projectURL.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        guard resolved.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    @objc private func openReference(_ sender: NSButton) {
        guard let button = sender as? PlanReferenceButton else { return }
        onOpenFile?(button.url.path.replacingOccurrences(of: projectURL.path + "/", with: ""))
    }
}

@MainActor
private final class PlanReferenceButton: NSButton {
    let url: URL

    init(path: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        title = path
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
