import AppKit
import EditorCore
import AgentContextCore
import AgentConnectionCore

/// The document editor used by the centre pane of a workspace window.
///
/// A text view belongs to each open document rather than being reused.  Apart from
/// retaining the normal AppKit undo stack, that also means a tab keeps its selection
/// and scroll position while another centre-pane view (such as TODOs) is visible.
@MainActor
final class TextEditorView: NSView, NSTabViewDelegate, NSTextViewDelegate {
    var onStateChange: (() -> Void)?
    var onActiveFileChange: ((URL?) -> Void)?
    var onFileSaved: ((URL) -> Void)?
    var onRevertAgentChange: ((AgentFileChangeHunk) -> Void)?
    var activeFileURL: URL? { tabView.selectedTabViewItem?.identifier as? URL }

    var hasOpenFiles: Bool { tabView.numberOfTabViewItems > 0 }
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }
    var isBusy: Bool { operationInProgress || preparingToClose }
    var canSave: Bool { activeDocument != nil && !isBusy }
    var canFind: Bool { activeDocument != nil && !isBusy }
    private var agentModifiedURLs = Set<URL>()
    private var agentChangeHunksByURL: [URL: [AgentFileChangeHunk]] = [:]
    private var activeAgentChangeIndex = 0
    private var activeAgentChangeReviewSheet: AgentChangeBlockReviewSheetController?

    func setAgentModifiedFiles(_ urls: Set<URL>) {
        agentModifiedURLs = Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        updateHeader()
    }

    func setAgentChangeHunks(_ hunksByURL: [URL: [AgentFileChangeHunk]]) {
        agentChangeHunksByURL = hunksByURL.mapValues { hunks in
            hunks.filter { !$0.isReverted }
        }
        for document in documents {
            refreshAgentChangeMarkers(for: document)
        }
        updateAgentChangeControls()
    }

    /// The file-change approval service calls this immediately before mutating a
    /// path. Reconcile delayed dirty checks so inactive tabs are protected too.
    func hasUnsavedEdits(at url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard let document = documentsByURL[canonical] else { return false }
        flushDirtyState(for: document)
        return document.isDirty
    }

    /// Reload an externally changed file only when its in-memory tab is clean.
    /// A dirty buffer always remains intact for the user to resolve.
    func reloadCleanDocument(at url: URL) async {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard let document = documentsByURL[canonical] else { return }
        flushDirtyState(for: document)
        guard !document.isDirty, !isBusy else { return }
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            remove(document)
            return
        }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try TextFileSnapshot.read(from: canonical)
            }.value
            guard documentsByURL[canonical] === document else { return }
            flushDirtyState(for: document)
            guard !document.isDirty else { return }
            document.snapshot = snapshot
            document.persistedText = snapshot.text
            document.textView.string = snapshot.text
            document.undoManager.removeAllActions()
            document.presentation.textDidChange()
            refreshAgentChangeMarkers(for: document)
            updatePosition()
            notifyStateChange()
        } catch {
            await present(error)
        }
    }

    @MainActor private final class Document: NSObject {
        var snapshot: TextFileSnapshot
        var persistedText: String
        let textView: CodeTextView
        let scrollView: NSScrollView
        let tab: NSTabViewItem
        let presentation: CodePresentation
        var previewView: DocumentPreviewView?
        let undoManager = UndoManager()
        var isDirty = false
        var pendingDirtyCheck: DispatchWorkItem?

        init(snapshot: TextFileSnapshot, textView: CodeTextView, scrollView: NSScrollView, tab: NSTabViewItem) {
            self.snapshot = snapshot
            self.persistedText = snapshot.text
            self.textView = textView
            self.scrollView = scrollView
            self.tab = tab
            self.presentation = CodePresentation(textView: textView, scrollView: scrollView, url: snapshot.url)
        }
    }

    private enum CloseDecision {
        case save
        case discard
        case cancel
    }

    private let tabView = NSTabView()
    private let tabBar = EditorTabBar()
    private let pathControl = NSPathControl()
    private let documentModeControl = NSSegmentedControl(
        labels: ["Preview", "Code"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let positionLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let contextButton = NSButton(title: "View Effective Context", target: nil, action: nil)
    private let agentChangesLabel = NSTextField(labelWithString: "✦")
    private let previousAgentChangeButton = NSButton(title: "", target: nil, action: nil)
    private let nextAgentChangeButton = NSButton(title: "", target: nil, action: nil)
    private let showOriginalButton = NSButton(title: "Original", target: nil, action: nil)
    private let revertAgentChangeButton = NSButton(title: "Revert", target: nil, action: nil)
    private let agentChangesBar = NSStackView()
    private let emptyState = NSTextField(wrappingLabelWithString: "Select a file in the explorer to start editing.")
    private var pathControlFullTrailing: NSLayoutConstraint!
    private var pathControlModeTrailing: NSLayoutConstraint!
    private var positionFullTrailing: NSLayoutConstraint!
    private var positionContextTrailing: NSLayoutConstraint!
    private var tabViewPathTop: NSLayoutConstraint!
    private var tabViewAgentChangesTop: NSLayoutConstraint!
    var onShowAgentContext: (() -> Void)?
    private var documents: [Document] = []
    private var documentsByURL: [URL: Document] = [:]
    private var imageTabs: [URL: NSTabViewItem] = [:]
    private var binaryTabs: [URL: NSTabViewItem] = [:]
    private var binaryPreviews: [URL: BinaryFilePreviewView] = [:]
    private var documentsByTextView: [ObjectIdentifier: Document] = [:]
    private var operationInProgress = false
    private var preparingToClose = false
    private var openingFile = false
    private var queuedOpenURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = true
        addSubview(tabView)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        tabBar.onSelect = { [weak self] url in
            guard let self, !self.isBusy, let tab = self.tab(for: url) else { return }
            self.tabView.selectTabViewItem(tab)
            self.focusEditor()
            self.onActiveFileChange?(self.activeFileURL)
        }
        tabBar.onClose = { [weak self] url in
            Task { [weak self] in
                guard let self, !self.isBusy, let tab = self.tab(for: url) else { return }
                self.tabView.selectTabViewItem(tab)
                await self.closeActive()
            }
        }
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: 11)
        // A long disk path must truncate, never widen the editor's split pane.
        pathControl.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        pathControl.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        pathControl.setAccessibilityLabel("Active file path")
        addSubview(pathControl)

        agentChangesLabel.font = .systemFont(ofSize: 11, weight: .medium)
        agentChangesLabel.textColor = .secondaryLabelColor
        agentChangesLabel.setAccessibilityLabel("AI change navigation")
        configureIconButton(
            previousAgentChangeButton,
            symbol: "chevron.up",
            label: "Previous AI change",
            target: self,
            action: #selector(selectPreviousAgentChange),
            controlSize: .small
        )
        configureIconButton(
            nextAgentChangeButton,
            symbol: "chevron.down",
            label: "Next AI change",
            target: self,
            action: #selector(selectNextAgentChange),
            controlSize: .small
        )
        configureAgentChangeButton(
            showOriginalButton,
            label: "Show original block",
            action: #selector(showOriginalAgentChange)
        )
        configureAgentChangeButton(
            revertAgentChangeButton,
            label: "Revert selected AI change block",
            action: #selector(revertSelectedAgentChange)
        )
        let agentChangesSpacer = NSView()
        agentChangesSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        agentChangesBar.addArrangedSubview(agentChangesLabel)
        agentChangesBar.addArrangedSubview(previousAgentChangeButton)
        agentChangesBar.addArrangedSubview(nextAgentChangeButton)
        agentChangesBar.addArrangedSubview(showOriginalButton)
        agentChangesBar.addArrangedSubview(revertAgentChangeButton)
        agentChangesBar.addArrangedSubview(agentChangesSpacer)
        agentChangesBar.orientation = .horizontal
        agentChangesBar.alignment = .centerY
        agentChangesBar.spacing = 6
        agentChangesBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentChangesBar.translatesAutoresizingMaskIntoConstraints = false
        agentChangesBar.isHidden = true
        addSubview(agentChangesBar)

        documentModeControl.translatesAutoresizingMaskIntoConstraints = false
        documentModeControl.controlSize = .small
        documentModeControl.target = self
        documentModeControl.action = #selector(changeDocumentPresentationMode)
        documentModeControl.setAccessibilityLabel("Document view mode")
        documentModeControl.setToolTip("View the rendered document", forSegment: 0)
        documentModeControl.setToolTip("Edit the source", forSegment: 1)
        // The path owns available width. This control may yield before it creates
        // intrinsic-size pressure on the centre pane at small split-view widths.
        documentModeControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        documentModeControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        documentModeControl.isHidden = true
        addSubview(documentModeControl)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 2
        emptyState.setAccessibilityLabel("No file selected")
        addSubview(emptyState)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = .systemFont(ofSize: 11)
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.lineBreakMode = .byTruncatingTail
        positionLabel.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
        positionLabel.setAccessibilityLabel("Editor position")
        addSubview(positionLabel)
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setContentCompressionResistancePriority(.init(rawValue: 210), for: .horizontal)
        contextLabel.setAccessibilityLabel("Agent Context summary")
        contextLabel.isHidden = true
        addSubview(contextLabel)
        contextButton.translatesAutoresizingMaskIntoConstraints = false
        contextButton.bezelStyle = .inline
        contextButton.controlSize = .small
        contextButton.target = self
        contextButton.action = #selector(showAgentContextInspector)
        contextButton.setAccessibilityLabel("View Effective Context")
        contextButton.isHidden = true
        addSubview(contextButton)

        pathControlFullTrailing = pathControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        pathControlModeTrailing = pathControl.trailingAnchor.constraint(equalTo: documentModeControl.leadingAnchor, constant: -8)
        positionFullTrailing = positionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        positionContextTrailing = positionLabel.trailingAnchor.constraint(equalTo: contextLabel.leadingAnchor, constant: -12)
        tabViewPathTop = tabView.topAnchor.constraint(equalTo: pathControl.bottomAnchor)
        tabViewAgentChangesTop = tabView.topAnchor.constraint(equalTo: agentChangesBar.bottomAnchor)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathControl.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pathControl.heightAnchor.constraint(equalToConstant: 26),
            agentChangesBar.topAnchor.constraint(equalTo: pathControl.bottomAnchor),
            agentChangesBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            agentChangesBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            agentChangesBar.heightAnchor.constraint(equalToConstant: 25),
            documentModeControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            documentModeControl.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            tabView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contextLabel.trailingAnchor.constraint(equalTo: contextButton.leadingAnchor, constant: -8),
            contextLabel.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),
            contextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contextButton.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),
            positionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28)
        ])
        pathControlFullTrailing.isActive = true
        positionFullTrailing.isActive = true
        tabViewPathTop.isActive = true
        updateVisibleState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configureAgentChangeButton(_ button: NSButton, label: String, action: Selector) {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    private var visibleAgentChanges: [AgentFileChangeHunk] {
        guard let document = activeDocument else { return [] }
        let url = document.snapshot.url.resolvingSymlinksInPath().standardizedFileURL
        return (agentChangeHunksByURL[url] ?? []).filter { hunk in
            !hunk.isReverted
        }
    }

    private func refreshAgentChangeMarkers(for document: Document) {
        let url = document.snapshot.url.resolvingSymlinksInPath().standardizedFileURL
        let ranges = (agentChangeHunksByURL[url] ?? []).compactMap { hunk -> NSRange? in
            guard !hunk.isReverted else { return nil }
            return hunk.locate(in: document.textView.string)
        }
        document.presentation.setAgentChangeRanges(ranges)
        if document === activeDocument { updateAgentChangeControls() }
    }

    private func updateAgentChangeControls() {
        let changes = visibleAgentChanges
        guard !changes.isEmpty else {
            agentChangesBar.isHidden = true
            tabViewAgentChangesTop.isActive = false
            tabViewPathTop.isActive = true
            return
        }
        activeAgentChangeIndex = min(max(0, activeAgentChangeIndex), changes.count - 1)
        agentChangesLabel.stringValue = "✦ \(activeAgentChangeIndex + 1)/\(changes.count)"
        agentChangesLabel.setAccessibilityValue("AI change \(activeAgentChangeIndex + 1) of \(changes.count)")
        previousAgentChangeButton.isEnabled = changes.count > 1
        nextAgentChangeButton.isEnabled = changes.count > 1
        let canLocate = activeDocument.map { changes[activeAgentChangeIndex].locate(in: $0.textView.string) != nil } ?? false
        revertAgentChangeButton.isEnabled = canLocate && !(activeDocument?.isDirty ?? true) && !isBusy
        revertAgentChangeButton.toolTip = (activeDocument?.isDirty ?? true)
            ? "Save or discard your edits before reverting this block."
            : (canLocate ? "Revert selected AI change block" : "This block has changed. Original remains available.")
        agentChangesBar.isHidden = false
        tabViewPathTop.isActive = false
        tabViewAgentChangesTop.isActive = true
    }

    private func selectAgentChange(at index: Int) {
        let changes = visibleAgentChanges
        guard !changes.isEmpty, let document = activeDocument else { return }
        activeAgentChangeIndex = (index + changes.count) % changes.count
        guard let range = changes[activeAgentChangeIndex].locate(in: document.textView.string) else {
            updateAgentChangeControls()
            return
        }
        document.previewView?.showCode()
        document.textView.setSelectedRange(range)
        document.textView.scrollRangeToVisible(range)
        document.textView.refreshCurrentLine()
        document.presentation.ruler.selectionDidChange()
        updateAgentChangeControls()
        updatePosition()
    }

    func selectAgentChange(_ hunk: AgentFileChangeHunk) {
        guard let index = visibleAgentChanges.firstIndex(where: {
            $0.recordID == hunk.recordID && $0.id == hunk.id
        }) else { return }
        selectAgentChange(at: index)
    }

    @objc private func selectPreviousAgentChange() {
        selectAgentChange(at: activeAgentChangeIndex - 1)
    }

    @objc private func selectNextAgentChange() {
        selectAgentChange(at: activeAgentChangeIndex + 1)
    }

    @objc private func showOriginalAgentChange() {
        let changes = visibleAgentChanges
        guard changes.indices.contains(activeAgentChangeIndex), let window else { return }
        let sheet = AgentChangeBlockReviewSheetController(hunk: changes[activeAgentChangeIndex])
        activeAgentChangeReviewSheet = sheet
        sheet.present(over: window) { [weak self] in
            self?.activeAgentChangeReviewSheet = nil
        }
    }

    @objc private func revertSelectedAgentChange() {
        let changes = visibleAgentChanges
        guard changes.indices.contains(activeAgentChangeIndex) else { return }
        onRevertAgentChange?(changes[activeAgentChangeIndex])
    }

    /// Opens a file or activates the tab that already owns its resolved URL.
    func open(_ url: URL) async {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        if openingFile {
            // The outline may advance while disk I/O is still in flight. Keeping just
            // the latest selection avoids a stale editor after a fast keyboard move.
            queuedOpenURL = resolvedURL
            return
        }
        if let existing = tab(for: resolvedURL) {
            tabView.selectTabViewItem(existing)
            focusEditor()
            return
        }
        guard !isBusy else { return }

        openingFile = true
        setOperationInProgress(true)
        defer {
            openingFile = false
            setOperationInProgress(false)
            onActiveFileChange?(activeFileURL)
        }
        var nextURL: URL? = resolvedURL
        while let urlToOpen = nextURL {
            if let existing = tab(for: urlToOpen) {
                tabView.selectTabViewItem(existing)
                focusEditor()
            } else if ImagePreviewView.supportsRaster(urlToOpen) {
                addImage(urlToOpen)
            } else if BinaryFilePreviewView.supportsQuickLook(url: urlToOpen) ||
                        BinaryFilePreviewView.shouldOpenWithoutTextDecoding(url: urlToOpen) {
                do {
                    try await Self.validateReadOnlyFile(urlToOpen)
                    addBinary(urlToOpen, reason: .binary)
                } catch {
                    await present(error)
                }
            } else {
                do {
                    let snapshot = try await Task.detached(priority: .userInitiated) {
                        try TextFileSnapshot.read(from: urlToOpen)
                    }.value
                    if documentsByURL[urlToOpen] == nil { addDocument(snapshot) }
                } catch let error as TextFileSnapshotError {
                    switch error {
                    case .binaryFile:
                        addBinary(urlToOpen, reason: .binary)
                    case .unsupportedEncoding:
                        addBinary(urlToOpen, reason: .unsupportedEncoding)
                    case .fileTooLarge:
                        addBinary(urlToOpen, reason: .tooLarge)
                    default:
                        await present(error)
                    }
                } catch {
                    await present(error)
                }
            }
            nextURL = queuedOpenURL
            queuedOpenURL = nil
        }
    }

    /// Saves the selected tab. The text view is locked until the write finishes.
    func saveActive() async {
        guard let document = activeDocument, !isBusy else { return }
        flushDirtyState(for: document)
        guard document.isDirty else { return }
        await save(document)
    }

    /// Asks about an unsaved selected tab, then closes it when allowed.
    @discardableResult
    func closeActive() async -> Bool {
        guard !isBusy else { return false }
        if let url = activeFileURL, let tab = imageTabs.removeValue(forKey: url) {
            tabView.removeTabViewItem(tab)
            updateVisibleState()
            notifyStateChange()
            return true
        }
        if let url = activeFileURL, let tab = binaryTabs.removeValue(forKey: url) {
            binaryPreviews.removeValue(forKey: url)?.close()
            tabView.removeTabViewItem(tab)
            updateVisibleState()
            notifyStateChange()
            return true
        }
        guard let document = activeDocument else { return false }
        flushDirtyState(for: document)
        if document.isDirty {
            setOperationInProgress(true)
            let decision = await askToSaveChanges(for: document)
            setOperationInProgress(false)
            switch decision {
            case .cancel:
                return false
            case .save:
                await save(document)
                guard !document.isDirty else { return false }
            case .discard:
                break
            }
        }
        remove(document)
        return true
    }

    /// Requests save decisions without closing tabs itself. This makes a cancelled
    /// later decision leave every draft available if the containing window remains.
    func prepareToClose() async -> Bool {
        guard !operationInProgress, !preparingToClose else { return false }
        preparingToClose = true
        notifyStateChange()
        defer {
            preparingToClose = false
            notifyStateChange()
        }

        for document in documents {
            flushDirtyState(for: document)
            guard document.isDirty else { continue }
            switch await askToSaveChanges(for: document) {
            case .cancel:
                return false
            case .discard:
                continue
            case .save:
                await save(document, allowedDuringClosePreparation: true)
                if document.isDirty { return false }
            }
        }
        return true
    }

    func focusEditor() {
        guard let document = activeDocument else {
            window?.makeFirstResponder(nil)
            return
        }
        if let preview = document.previewView, preview.isShowingPreview {
            window?.makeFirstResponder(documentModeControl)
        } else {
            window?.makeFirstResponder(document.textView)
        }
    }

    func find() {
        guard let document = activeDocument else { return }
        document.previewView?.showCode()
        let textView = document.textView
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    /// Moves the active text document to a one-based logical line without
    /// changing its buffer or closing any existing tabs and drafts.
    func select(line: Int) {
        guard line > 0, let document = activeDocument else { return }
        document.previewView?.showCode()
        let index = LineIndex(text: document.textView.string)
        let lineIndex = min(line, index.lineCount) - 1
        let range = NSRange(location: index.lineStarts[lineIndex], length: 0)
        document.textView.setSelectedRange(range)
        document.textView.scrollRangeToVisible(range)
        focusEditor()
        updatePosition()
    }

    func showAgentContext(_ resolution: ContextResolution?) {
        guard let resolution, activeFileURL != nil else {
            contextLabel.toolTip = nil
            contextLabel.textColor = .secondaryLabelColor
            contextLabel.isHidden = true
            contextButton.isHidden = true
            positionContextTrailing.isActive = false
            positionFullTrailing.isActive = true
            return
        }
        let active = resolution.entries.filter { $0.state == .active }.count
        contextLabel.stringValue = "Agent Context · \(active) rule\(active == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(resolution.utf8ByteCount), countStyle: .file))"
        contextLabel.toolTip = resolution.entries.map { entry in
            let order = entry.order.map(String.init) ?? "—"
            return "\(order). \(entry.rule.name) · \(entry.rule.provider.rawValue) · priority \(entry.rule.priority) · \(entry.state.rawValue)"
        }.joined(separator: "\n")
        contextLabel.textColor = resolution.diagnostics.contains(where: { $0.kind == .oversize }) ? .systemOrange : .secondaryLabelColor
        contextLabel.isHidden = false
        contextButton.isHidden = false
        positionFullTrailing.isActive = false
        positionContextTrailing.isActive = true
    }

    @objc private func showAgentContextInspector() { onShowAgentContext?() }

    // MARK: Document setup

    private func tab(for url: URL) -> NSTabViewItem? {
        documentsByURL[url]?.tab ?? imageTabs[url] ?? binaryTabs[url]
    }

    private func addImage(_ url: URL) {
        let tab = NSTabViewItem(identifier: url)
        let preview = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        // NSTabView sizes its item view using autoresizing, not edge constraints.
        preview.translatesAutoresizingMaskIntoConstraints = true
        preview.autoresizingMask = [.width, .height]
        tab.view = preview
        tab.label = url.lastPathComponent
        tab.toolTip = url.path
        imageTabs[url] = tab
        tabView.addTabViewItem(tab)
        tabView.selectTabViewItem(tab)
        preview.loadRaster(from: url)
        updateVisibleState()
        notifyStateChange()
        focusEditor()
    }

    private func addBinary(_ url: URL, reason: BinaryFilePreviewView.Reason) {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let tab = NSTabViewItem(identifier: canonicalURL)
        let preview = BinaryFilePreviewView(
            url: canonicalURL,
            allowsQuickLook: BinaryFilePreviewView.supportsQuickLook(url: canonicalURL),
            reason: reason
        )
        preview.translatesAutoresizingMaskIntoConstraints = true
        preview.autoresizingMask = [.width, .height]
        tab.view = preview
        tab.label = canonicalURL.lastPathComponent
        tab.toolTip = canonicalURL.path
        binaryTabs[canonicalURL] = tab
        binaryPreviews[canonicalURL] = preview
        tabView.addTabViewItem(tab)
        tabView.selectTabViewItem(tab)
        updateVisibleState()
        notifyStateChange()
        focusEditor()
    }

    private var activeDocument: Document? {
        guard let url = tabView.selectedTabViewItem?.identifier as? URL else { return nil }
        return documentsByURL[url]
    }

    private func addDocument(_ snapshot: TextFileSnapshot) {
        let textView = makeTextView()
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        // Keep ruler drawing inside the tab's document area.
        scrollView.clipsToBounds = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let canonicalURL = snapshot.url.resolvingSymlinksInPath().standardizedFileURL
        let tab = NSTabViewItem(identifier: canonicalURL)
        tab.view = scrollView
        tab.initialFirstResponder = textView
        textView.string = snapshot.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let document = Document(snapshot: snapshot, textView: textView, scrollView: scrollView, tab: tab)
        let previewKind: DocumentPreviewView.Kind?
        switch snapshot.url.pathExtension.lowercased() {
        case "svg": previewKind = .svg
        case "md", "markdown": previewKind = .markdown
        default: previewKind = nil
        }
        if let previewKind {
            let preview = DocumentPreviewView(editor: scrollView, source: { [weak textView] in textView?.string ?? "" }, kind: previewKind)
            document.previewView = preview
            tab.view = preview
            tab.initialFirstResponder = nil
            preview.onModeChange = { [weak self] in
                guard let self else { return }
                self.updateHeader()
                self.updatePosition()
                self.focusEditor()
            }
        }
        document.presentation.onLanguageChange = { [weak self] in self?.updatePosition() }
        textView.delegate = self
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoHistoryDidChange(_:)),
                                                   name: name, object: document.undoManager)
        }

        documents.append(document)
        documentsByURL[canonicalURL] = document
        documentsByTextView[ObjectIdentifier(textView)] = document
        refreshAgentChangeMarkers(for: document)
        updateTabLabel(for: document)
        tab.toolTip = snapshot.url.path
        tabView.addTabViewItem(tab)
        tabView.selectTabViewItem(tab)
        updateVisibleState()
        notifyStateChange()
        focusEditor()
    }

    private func makeTextView() -> CodeTextView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("File editor")
        return textView
    }

    private func remove(_ document: Document) {
        document.pendingDirtyCheck?.cancel()
        NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: document.undoManager)
        NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: document.undoManager)
        documents.removeAll { $0 === document }
        documentsByURL.removeValue(forKey: document.snapshot.url)
        documentsByTextView.removeValue(forKey: ObjectIdentifier(document.textView))
        document.tab.identifier = nil
        tabView.removeTabViewItem(document.tab)
        updateVisibleState()
        notifyStateChange()
    }

    private func updateVisibleState() {
        let hasDocuments = hasOpenFiles
        tabView.isHidden = !hasDocuments
        emptyState.isHidden = hasDocuments
        positionLabel.isHidden = !hasDocuments
        if !hasDocuments { showAgentContext(nil) }
        tabBar.isHidden = !hasDocuments
        pathControl.isHidden = !hasDocuments
        updateHeader()
        updatePosition()
        updateBinaryPreviewActivation()
        onActiveFileChange?(activeFileURL)
    }

    private func updateTabLabel(for document: Document) {
        document.tab.label = document.isDirty ? "• \(document.snapshot.url.lastPathComponent)" : document.snapshot.url.lastPathComponent
        updateHeader()
    }

    // MARK: Saving and dirty state

    private func save(_ document: Document, allowedDuringClosePreparation: Bool = false) async {
        guard document.isDirty, !operationInProgress, (!preparingToClose || allowedDuringClosePreparation) else { return }
        setOperationInProgress(true)
        document.textView.isEditable = false
        document.textView.breakUndoCoalescing()
        defer {
            document.textView.isEditable = true
            setOperationInProgress(false)
        }

        let snapshot = document.snapshot
        let textToSave = document.textView.string
        do {
            let savedSnapshot = try await Task.detached(priority: .userInitiated) {
                return try snapshot.save(text: textToSave)
            }.value
            document.snapshot = savedSnapshot
            // Keep the AppKit buffer's representation as the baseline. EditorCore
            // deliberately returns CRLF text for CRLF files, while NSTextView may
            // normalize its buffer to LF; using the returned text here would leave a
            // freshly saved CRLF document marked dirty.
            document.persistedText = textToSave
            document.pendingDirtyCheck?.cancel()
            document.pendingDirtyCheck = nil
            refreshDirtyState(for: document)
            onFileSaved?(document.snapshot.url)
        } catch {
            await present(error)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let document = documentsByTextView[ObjectIdentifier(textView)] else { return }
        document.presentation.textDidChange()
        refreshAgentChangeMarkers(for: document)
        updatePosition()
        if !document.isDirty {
            document.isDirty = true
            updateTabLabel(for: document)
            notifyStateChange()
        }
        scheduleDirtyCheck(for: document)
    }

    @objc private func undoHistoryDidChange(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager,
              let document = documents.first(where: { $0.undoManager === manager }) else { return }
        // AppKit can restore a buffer through Undo without a delegate text-change
        // callback after switching presentations. Reconcile the document itself.
        document.presentation.textDidChange()
        flushDirtyState(for: document)
        updatePosition()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        documentsByTextView[ObjectIdentifier(view)]?.undoManager
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateBinaryPreviewActivation()
        focusEditor()
        updateHeader()
        updateAgentChangeControls()
        updatePosition()
        onActiveFileChange?(activeFileURL)
        notifyStateChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView,
              let document = documentsByTextView[ObjectIdentifier(view)] else { return }
        document.textView.refreshCurrentLine()
        document.presentation.ruler.selectionDidChange()
        updatePosition()
    }

    private func updateHeader() {
        let url = activeFileURL
        tabBar.update(items: tabView.tabViewItems.compactMap { tab in
            guard let fileURL = tab.identifier as? URL else { return nil }
            return EditorTabBar.Item(url: fileURL, title: fileURL.lastPathComponent,
                                     isDirty: documentsByURL[fileURL]?.isDirty ?? false,
                                     isAgentModified: agentModifiedURLs.contains(fileURL))
        }, selectedURL: url)
        if pathControl.url != url { pathControl.url = url }
        pathControl.toolTip = url?.path
        updateDocumentModeControl()
    }

    private func updateDocumentModeControl() {
        guard let preview = activeDocument?.previewView else {
            documentModeControl.isHidden = true
            pathControlModeTrailing.isActive = false
            pathControlFullTrailing.isActive = true
            return
        }
        documentModeControl.isHidden = false
        documentModeControl.selectedSegment = preview.isShowingPreview ? 0 : 1
        pathControlFullTrailing.isActive = false
        pathControlModeTrailing.isActive = true
    }

    @objc private func changeDocumentPresentationMode() {
        guard let preview = activeDocument?.previewView else { return }
        if documentModeControl.selectedSegment == 1 {
            preview.showCode()
        } else {
            preview.showPreview()
        }
    }

    private func updatePosition() {
        guard let document = activeDocument else {
            if let url = activeFileURL, binaryTabs[url] != nil {
                positionLabel.stringValue = "Read Only · Preview"
            } else {
                positionLabel.stringValue = hasOpenFiles ? "Image · Read Only" : ""
            }
            return
        }
        if document.previewView?.isShowingPreview == true {
            let format = document.snapshot.url.pathExtension.lowercased() == "svg" ? "SVG" : "Markdown"
            positionLabel.stringValue = "\(format) · Preview"
            return
        }
        let position = document.presentation.ruler.position(atUTF16Offset: document.textView.selectedRange().location)
        positionLabel.stringValue = "\(document.presentation.language.displayName) · Ln \(position.line), Col \(position.column)"
    }

    private func scheduleDirtyCheck(for document: Document) {
        document.pendingDirtyCheck?.cancel()
        let check = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            self.refreshDirtyState(for: document)
        }
        document.pendingDirtyCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: check)
    }

    private func refreshDirtyState(for document: Document) {
        document.pendingDirtyCheck = nil
        let isDirty = !document.textView.string.utf8.elementsEqual(document.persistedText.utf8)
        guard document.isDirty != isDirty else { return }
        document.isDirty = isDirty
        updateTabLabel(for: document)
        notifyStateChange()
    }

    private func flushDirtyState(for document: Document) {
        document.pendingDirtyCheck?.cancel()
        document.pendingDirtyCheck = nil
        refreshDirtyState(for: document)
    }

    // MARK: Sheets

    private func askToSaveChanges(for document: Document) async -> CloseDecision {
        guard let hostWindow = window else { return .cancel }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.snapshot.url.lastPathComponent)”?"
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

    private func present(_ error: Error) async {
        guard let hostWindow = window else { return }
        let alert = NSAlert(error: error)
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: hostWindow) { _ in continuation.resume() }
        }
    }

    private func updateBinaryPreviewActivation() {
        let activeURL = activeFileURL
        for (url, preview) in binaryPreviews {
            if url == activeURL {
                preview.activate()
            } else {
                preview.deactivate()
            }
        }
    }

    private static func validateReadOnlyFile(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw TextFileSnapshotError.notRegularFile }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        }.value
    }

    private func setOperationInProgress(_ value: Bool) {
        guard operationInProgress != value else { return }
        operationInProgress = value
        notifyStateChange()
    }

    private func notifyStateChange() {
        onStateChange?()
    }
}

@MainActor
private final class AgentChangeBlockReviewSheetController: NSWindowController, NSWindowDelegate {
    private var completion: (() -> Void)?

    private final class ReviewWindow: NSWindow {
        var onCancel: (() -> Void)?

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    init(hunk: AgentFileChangeHunk) {
        let window = ReviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Review AI Change"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.dismiss() }

        let path = NSTextField(labelWithString: "\(hunk.relativePath) · Applied at line \(hunk.newStartLine)")
        path.font = .systemFont(ofSize: 12, weight: .medium)
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = hunk.relativePath
        let originalLabel = NSTextField(labelWithString: "Original")
        originalLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let currentLabel = NSTextField(labelWithString: "Applied by AI")
        currentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let original = Self.makeTextView(hunk.beforeText)
        let current = Self.makeTextView(hunk.afterText)
        let close = NSButton(title: "Close", target: nil, action: nil)
        close.keyEquivalent = "\r"
        close.target = self
        close.action = #selector(closeSheet)
        let actions = NSStackView(views: [NSView(), close])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.arrangedSubviews[0].setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        let content = NSStackView(views: [path, originalLabel, original, currentLabel, current, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        window.contentView = container
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            path.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            originalLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            original.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            original.heightAnchor.constraint(equalToConstant: 150),
            currentLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            current.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            current.heightAnchor.constraint(equalToConstant: 150),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(over host: NSWindow, completion: @escaping () -> Void) {
        self.completion = completion
        host.beginSheet(window!) { [weak self] _ in
            self?.completion?()
            self?.completion = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: .cancel)
    }

    @objc private func closeSheet() { dismiss() }

    private static func makeTextView(_ text: String) -> NSScrollView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }
}
