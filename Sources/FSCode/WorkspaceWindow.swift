import AppKit
import ProjectLibrary
import AgentContextCore
import AgentConnectionCore

@MainActor final class FileNode: NSObject {
    let url: URL
    private var children: [FileNode]?

    init(_ url: URL) { self.url = url }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    func loadChildren() -> [FileNode] {
        if let children { return children }

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            children = []
            return []
        }

        let nodes = urls.map(FileNode.init).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        children = nodes
        return nodes
    }

    func invalidateChildren() {
        children = nil
    }
}

@MainActor final class WorkspaceWindow: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSToolbarDelegate, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private let root: FileNode
    private let outline: NSOutlineView
    private var synchronizingFileSelection = false
    private let textEditor = TextEditorView()
    private let contextStore: ContextStore
    private let agentContextView: AgentContextView
    private let planEditorView: PlanEditorView
    private let contextWatcher: AgentContextWatcher
    private var contextCatalog: ContextCatalogSnapshot?
    private var activeContextResolution: ContextResolution?
    private var contextRefreshTask: Task<Void, Never>?
    private var contextResolveTask: Task<Void, Never>?
    private var contextRefreshGeneration = 0
    private var contextResolveGeneration = 0
    private var closing = false
    private var allowClose = false
    private var workspaceClosed = false
    private let workspaceSplit: NSSplitViewController
    private let editorSplit: NSSplitViewController
    private let sidebarItem: NSSplitViewItem
    private let centerItem: NSSplitViewItem
    private let assistantItem: NSSplitViewItem
    private let terminalItem: NSSplitViewItem
    private let terminalPane: TerminalPaneView
    private let projectSidebar: ProjectSidebarView
    private let connectionManager: AgentConnectionManager
    private let assistantConnectionView: AssistantConnectionView
    private let permissionsView: PermissionsView
    private let capabilityStore: ProjectCapabilityStore
    private let computerUseService = NativeComputerUseService()
    private var capabilityApprovalContinuation: CheckedContinuation<Bool, Never>?
    private weak var capabilityApprovalSheet: NSWindow?
    private var agentModifiedURLs = Set<URL>()
    private var displayedAgentChangeRecords: [AgentFileChangeRecord] = []
    private let launchesTerminal: Bool
    private var lastVisibleSidebarWidth: CGFloat = 240
    private var lastVisibleAssistantWidth: CGFloat = 300
    private var lastVisibleTerminalHeight: CGFloat = 200

    private let sidebarIdentifier = NSToolbarItem.Identifier("fs-code.sidebar")
    private let assistantIdentifier = NSToolbarItem.Identifier("fs-code.assistant")
    private let terminalIdentifier = NSToolbarItem.Identifier("fs-code.terminal")

    init(project: Project, url: URL, launchesTerminal: Bool = true) {
        let root = FileNode(url)
        let outline = NSOutlineView()
        let workspaceSplit = NSSplitViewController()
        let editorSplit = NSSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.root = root
        self.outline = outline
        self.workspaceSplit = workspaceSplit
        self.editorSplit = editorSplit
        self.window = window
        self.launchesTerminal = launchesTerminal
        let globalContextURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FS Code", isDirectory: true)
            .appendingPathComponent("context", isDirectory: true)
        self.contextStore = ContextStore(configuration: .init(projectURL: url, globalStoreURL: globalContextURL))
        self.contextWatcher = AgentContextWatcher(projectURL: url, globalStoreURL: globalContextURL)
        self.connectionManager = AgentConnectionManager(projectURL: url, projectID: project.id)
        let agentContextView = AgentContextView()
        self.agentContextView = agentContextView
        agentContextView.configureSystemPrompts(projectURL: url)
        let planEditorView = PlanEditorView(projectURL: url)
        self.planEditorView = planEditorView
        let permissionsView = PermissionsView(projectURL: url)
        self.permissionsView = permissionsView
        self.capabilityStore = ProjectCapabilityStore(projectURL: url)

        let sidebar = NSViewController()
        let projectSidebar = ProjectSidebarView(
            outline: outline,
            projectURL: url,
            agentContextSidebar: agentContextView.sidebarView,
            plansSidebar: planEditorView.sidebarView,
            permissionsSidebar: permissionsView
        )
        self.projectSidebar = projectSidebar
        sidebar.view = projectSidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        self.sidebarItem = sidebarItem

        let editor = NSViewController()
        let fileView = textEditor
        let content = NSView()
        let todoView = projectSidebar.todoDetailView
        todoView.isHidden = true
        agentContextView.isHidden = true
        planEditorView.isHidden = true
        for view in [fileView, todoView, planEditorView, agentContextView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        editor.view = content
        projectSidebar.onViewChanged = { mode in
            // A hidden editor must not continue receiving typing or Undo commands.
            fileView.window?.makeFirstResponder(nil)
            fileView.isHidden = mode != .files && mode != .permissions
            todoView.isHidden = mode != .todos
            planEditorView.isHidden = mode != .plans
            agentContextView.isHidden = mode != .agentContext
            if mode == .plans {
                planEditorView.reload()
            }
            if mode == .permissions {
                permissionsView.refresh()
            }
            if mode == .files {
                fileView.focusEditor()
                fileView.onActiveFileChange?(fileView.activeFileURL)
            }
        }
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 220

        let terminal = NSViewController()
        let terminalPane = TerminalPaneView(projectURL: url)
        self.terminalPane = terminalPane
        terminal.view = terminalPane
        let terminalItem = NSSplitViewItem(viewController: terminal)
        self.terminalItem = terminalItem

        editorSplit.splitView.isVertical = false
        editorSplit.splitView.dividerStyle = .thin
        editorSplit.addSplitViewItem(editorItem)
        editorSplit.addSplitViewItem(terminalItem)
        let center = NSViewController()
        let centerContainer = NSView()
        center.view = centerContainer
        center.addChild(editorSplit)
        editorSplit.view.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(editorSplit.view)
        NSLayoutConstraint.activate([
            editorSplit.view.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            editorSplit.view.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
            editorSplit.view.topAnchor.constraint(equalTo: centerContainer.safeAreaLayoutGuide.topAnchor),
            editorSplit.view.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor)
        ])
        let centerItem = NSSplitViewItem(viewController: center)
        self.centerItem = centerItem

        let assistant = NSViewController()
        let assistantConnectionView = AssistantConnectionView(manager: connectionManager, projectURL: url)
        self.assistantConnectionView = assistantConnectionView
        assistant.view = assistantConnectionView
        let assistantItem = NSSplitViewItem(inspectorWithViewController: assistant)
        self.assistantItem = assistantItem

        super.init()
        assistantConnectionView.configureHostToolHandlers(
            requestCapability: { [weak self] request in
                guard let self else { return .rejected("The workspace is no longer available.") }
                return await self.requestProjectCapability(request)
            },
            computerUse: { [weak self] request in
                guard let self else { return .rejected("The workspace is no longer available.") }
                guard await self.capabilityStore.isEnabled(.computerUse) else {
                    return .rejected("Computer Use is disabled for this project.")
                }
                return await self.computerUseService.handle(request)
            }
        )
        assistantConnectionView.configureFileMutationHandlers(
            authorize: { [weak self] relativePath, operation in
                await self?.authorizeFileMutation(relativePath: relativePath, operation: operation) ?? false
            },
            didComplete: { [weak self] result in
                self?.completeFileMutation(result)
            }
        )
        assistantConnectionView.configureAgentModifiedPathsObserver { [weak self] paths in
            self?.setAgentModifiedFiles(paths)
        }
        assistantConnectionView.configureAppliedChangesObserver { [weak self] records in
            self?.setAgentChangeRecords(records)
        }
        assistantConnectionView.configureAgentChangeOpenHandler { [weak self] hunk in
            self?.openAgentChange(hunk)
        }
        assistantConnectionView.configureProjectFileOpenHandler { [weak self] relativePath in
            self?.openMentionedProjectFile(relativePath)
        }
        textEditor.onRevertAgentChange = { [weak assistantConnectionView] hunk in
            assistantConnectionView?.revertAgentChange(hunk)
        }
        terminalPane.onHide = { [weak self] in self?.toggleTerminal() }
        projectSidebar.onOpenFile = { [weak self] url, line in
            guard let self else { return }
            self.projectSidebar.showFiles { [weak self] in
                Task {
                    guard let self else { return }
                    await self.textEditor.open(url)
                    self.textEditor.select(line: line)
                }
            }
        }
        textEditor.onStateChange = { [weak self] in
            guard let self else { return }
            self.window.isDocumentEdited = self.textEditor.hasUnsavedChanges
        }
        textEditor.onActiveFileChange = { [weak self] url in
            self?.revealActiveFile(url)
            self?.resolveAgentContext(for: url)
        }
        configureAgentContextCallbacks()
        projectSidebar.requestLeaveAgentContext = { [weak agentContextView] completion in
            Task { completion(await agentContextView?.prepareToLeave() ?? true) }
        }
        projectSidebar.requestLeavePlans = { [weak planEditorView] completion in
            Task { completion(await planEditorView?.prepareToLeave() ?? true) }
        }
        planEditorView.onRun = { [weak assistantConnectionView] planID in
            guard let assistantConnectionView else { throw CancellationError() }
            try await assistantConnectionView.executePlan(planID: planID)
        }
        planEditorView.onOpenFile = { [weak self] relativePath in
            guard let self else { return }
            let url = self.root.url.appendingPathComponent(relativePath)
            self.projectSidebar.showFiles {
                Task { await self.textEditor.open(url) }
            }
        }
        textEditor.onFileSaved = { [weak self] url in
            guard let self, self.contextWatcher.isRelevant(url) else { return }
            self.refreshAgentContext()
        }
        refreshAgentContext()
        contextWatcher.onChange = { [weak self] _ in self?.refreshAgentContext() }
        contextWatcher.start()
        configureFileTree()
        configureSplitViews()
        configureWindow(projectName: project.name)
    }

    private func configureWindow(projectName: String) {
        window.title = projectName
        window.minSize = NSSize(width: 800, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = workspaceSplit

        let toolbar = NSToolbar(identifier: "fs-code.workspace-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreOrApplyDefaultLayout()
            self.window.contentView?.layoutSubtreeIfNeeded()
            if self.launchesTerminal, !self.terminalItem.isCollapsed { self.terminalPane.startIfNeeded() }
        }
    }

    private func configureAgentContextCallbacks() {
        agentContextView.onCreate = { [weak self] name, scope, target, priority, content in
            guard let self else { throw CancellationError() }
            return try await self.contextStore.create(name: name, scope: scope, target: target, priority: priority, content: content)
        }
        agentContextView.onUpdate = { [weak self] id, hash, name, scope, target, priority, enabled, content in
            guard let self else { throw CancellationError() }
            return try await self.contextStore.update(
                id: id, expectedHash: hash, name: name, scope: scope, target: target,
                priority: priority, enabled: enabled, content: content
            )
        }
        agentContextView.onRemove = { [weak self] id in
            guard let self else { throw CancellationError() }
            try await self.contextStore.remove(id: id)
        }
        agentContextView.onSetActivation = { [weak self] id, enabled in
            guard let self else { throw CancellationError() }
            return try await self.contextStore.setActivation(id: id, enabled: enabled)
        }
        agentContextView.onOpenSource = { [weak self] url in
            self?.projectSidebar.showFiles { [weak self] in
                Task { await self?.textEditor.open(url) }
            }
        }
        connectionManager.resolveAgentInstructions = { [weak self] in
            guard let self, !self.closing, !self.workspaceClosed else { throw AgentConnectionError.cancelled }
            let snapshot = try await self.contextStore.load()
            let paths = self.textEditor.activeFileURL.map { [$0] } ?? []
            let resolution = await self.contextStore.resolve(snapshot: snapshot, paths: paths)
            guard resolution.canSend else {
                throw AgentConnectionError.unavailable("Resolve the instruction errors in Agent Context before sending.")
            }
            return resolution.consolidatedText
        }
        agentContextView.onRefresh = { [weak self] in self?.refreshAgentContext() }
        textEditor.onShowAgentContext = { [weak self] in self?.showContextInspector() }
    }

    private func refreshAgentContext() {
        guard !closing, !workspaceClosed else { return }
        contextRefreshTask?.cancel()
        contextResolveTask?.cancel()
        contextRefreshGeneration += 1
        contextResolveGeneration += 1
        activeContextResolution = nil
        textEditor.showAgentContext(nil)
        let generation = contextRefreshGeneration
        contextRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.contextStore.load()
                guard !Task.isCancelled, generation == self.contextRefreshGeneration else { return }
                self.contextCatalog = snapshot
                self.agentContextView.apply(snapshot)
                self.contextWatcher.updateKnownSources(snapshot.rules.compactMap(\.url))
                self.resolveAgentContext(for: self.textEditor.activeFileURL)
            } catch {
                guard !Task.isCancelled, generation == self.contextRefreshGeneration else { return }
                self.contextResolveTask?.cancel()
                self.contextResolveGeneration += 1
                self.contextCatalog = nil
                self.activeContextResolution = nil
                self.textEditor.showAgentContext(nil)
                self.agentContextView.showCatalogError(error)
            }
        }
    }

    private func resolveAgentContext(for url: URL?) {
        contextResolveTask?.cancel()
        contextResolveGeneration += 1
        let generation = contextResolveGeneration
        activeContextResolution = nil
        textEditor.showAgentContext(nil)
        guard let url, let snapshot = contextCatalog else {
            return
        }
        contextResolveTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await self.contextStore.resolve(snapshot: snapshot, paths: [url])
            guard !Task.isCancelled,
                  generation == self.contextResolveGeneration,
                  self.textEditor.activeFileURL == url else { return }
            self.activeContextResolution = resolution
            self.textEditor.showAgentContext(resolution)
        }
    }

    private func showContextInspector() {
        guard window.attachedSheet == nil,
              let resolution = activeContextResolution,
              let fileURL = textEditor.activeFileURL else { return }
        let inspector = AgentContextInspector(resolution: resolution, fileURL: fileURL)
        inspector.onOpenSource = { [weak self] url in
            self?.projectSidebar.showFiles { [weak self] in Task { await self?.textEditor.open(url) } }
        }
        inspector.onShowInAgentContext = { [weak self] id in
            self?.projectSidebar.showAgentContext { [weak self] in self?.agentContextView.selectRule(id: id) }
        }
        inspector.present(over: window)
    }

    private func configureSplitViews() {
        workspaceSplit.splitView.isVertical = true
        workspaceSplit.splitView.dividerStyle = .thin
        workspaceSplit.addSplitViewItem(sidebarItem)
        workspaceSplit.addSplitViewItem(centerItem)
        workspaceSplit.addSplitViewItem(assistantItem)

        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = .init(rawValue: 480)
        centerItem.minimumThickness = 340
        centerItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        centerItem.holdingPriority = .defaultLow
        assistantItem.minimumThickness = 260
        // Keep the inspector effectively unbounded for practical window sizes;
        // CGFloat.greatestFiniteMagnitude exceeds AppKit's constraint limits.
        assistantItem.maximumThickness = 10_000
        assistantItem.canCollapse = true
        assistantItem.canCollapseFromWindowResize = false
        assistantItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        assistantItem.holdingPriority = .init(rawValue: 480)
        terminalItem.minimumThickness = 130
        terminalItem.maximumThickness = 440
        terminalItem.canCollapse = true
        terminalItem.canCollapseFromWindowResize = false
        terminalItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        terminalItem.holdingPriority = .init(rawValue: 480)
        editorSplit.splitViewItems.first?.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        editorSplit.splitViewItems.first?.holdingPriority = .defaultLow
    }

    private func configureFileTree() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelectedFile)
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.registerForDraggedTypes([.fileURL])
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, !node.isDirectory else { return nil }
        return node.url as NSURL
    }

    private func reloadProjectTree() {
        root.invalidateChildren()
        outline.reloadData()
    }

    private func authorizeFileMutation(
        relativePath: String,
        operation: ConversationFileMutationOperation
    ) async -> Bool {
        guard !workspaceClosed, !closing, window.attachedSheet == nil else { return false }
        let target = root.url.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = root.url.path.hasSuffix("/") ? root.url.path : root.url.path + "/"
        guard target.path.hasPrefix(rootPrefix) else { return false }
        guard textEditor.hasUnsavedEdits(at: target) else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save your open changes first"
        let action = operation == .apply ? "apply this change" : "revert this change"
        alert.informativeText = "Save or discard the unsaved edits in \(relativePath) before FS Code can \(action)."
        alert.addButton(withTitle: "OK")
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { _ in continuation.resume() }
        }
        return false
    }

    private func completeFileMutation(_ result: ConversationFileMutationResult) {
        guard !workspaceClosed else { return }
        let target = root.url.appendingPathComponent(result.relativePath).standardizedFileURL
        reloadProjectTree()
        revealActiveFile(textEditor.activeFileURL)
        refreshAgentContext()
        Task { [weak self] in
            await self?.textEditor.reloadCleanDocument(at: target)
        }
    }

    private func setAgentModifiedFiles(_ relativePaths: Set<String>) {
        let projectURL = root.url.resolvingSymlinksInPath().standardizedFileURL
        let projectPrefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        let nextURLs = Set(relativePaths.compactMap { relativePath in
            let url = projectURL.appendingPathComponent(relativePath).standardizedFileURL
            return url.path.hasPrefix(projectPrefix) ? url : nil
        })
        guard nextURLs != agentModifiedURLs else { return }
        agentModifiedURLs = nextURLs
        textEditor.setAgentModifiedFiles(agentModifiedURLs)
        outline.reloadData()
        revealActiveFile(textEditor.activeFileURL)
    }

    private func setAgentChangeRecords(_ records: [AgentFileChangeRecord]) {
        guard records != displayedAgentChangeRecords else { return }
        displayedAgentChangeRecords = records
        let projectURL = root.url.resolvingSymlinksInPath().standardizedFileURL
        let projectPrefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        var hunksByURL: [URL: [AgentFileChangeHunk]] = [:]
        for record in records where record.status == .applied {
            for hunk in record.changeHunks {
                let url = projectURL.appendingPathComponent(hunk.relativePath).standardizedFileURL
                guard url.path.hasPrefix(projectPrefix) else { continue }
                hunksByURL[url, default: []].append(hunk)
            }
        }
        textEditor.setAgentChangeHunks(hunksByURL)
    }

    private func openAgentChange(_ hunk: AgentFileChangeHunk) {
        guard !workspaceClosed, !closing else { return }
        let target = root.url.appendingPathComponent(hunk.relativePath).standardizedFileURL
        let rootPrefix = root.url.path.hasSuffix("/") ? root.url.path : root.url.path + "/"
        guard target.path.hasPrefix(rootPrefix) else { return }
        projectSidebar.showFiles { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await self.textEditor.open(target)
                self.textEditor.selectAgentChange(hunk)
            }
        }
    }

    private func openMentionedProjectFile(_ relativePath: String) {
        guard !workspaceClosed, !closing, !relativePath.contains("..") else { return }
        let target = root.url.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard target.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: target.path) else { return }
        projectSidebar.showFiles { [weak self] in Task { await self?.textEditor.open(target) } }
    }

    private func restoreOrApplyDefaultLayout() {
        guard let layout = UserDefaults.standard.dictionary(forKey: layoutAutosaveName("layout")) as? [String: Double] else {
            resetLayout()
            return
        }
        lastVisibleSidebarWidth = layout["sidebar"] ?? 240
        lastVisibleAssistantWidth = layout["assistant"] ?? 300
        lastVisibleTerminalHeight = layout["terminal"] ?? 200
        workspaceSplit.splitView.adjustSubviews()
        editorSplit.splitView.adjustSubviews()
        workspaceSplit.splitView.setPosition(
            lastVisibleSidebarWidth,
            ofDividerAt: 0
        )
        workspaceSplit.splitView.layoutSubtreeIfNeeded()
        lastVisibleAssistantWidth = clampedAssistantWidth(lastVisibleAssistantWidth)
        workspaceSplit.splitView.setPosition(
            workspaceSplit.splitView.bounds.width
                - lastVisibleAssistantWidth
                - workspaceSplit.splitView.dividerThickness,
            ofDividerAt: 1
        )
        editorSplit.splitView.setPosition(
            max(260, editorSplit.splitView.bounds.height - lastVisibleTerminalHeight - editorSplit.splitView.dividerThickness),
            ofDividerAt: 0
        )
    }

    func resetLayout() {
        lastVisibleSidebarWidth = 240
        lastVisibleAssistantWidth = 300
        lastVisibleTerminalHeight = 200
        sidebarItem.isCollapsed = false
        assistantItem.isCollapsed = false
        terminalItem.isCollapsed = false
        workspaceSplit.splitView.adjustSubviews()
        editorSplit.splitView.adjustSubviews()
        workspaceSplit.splitView.setPosition(
            240,
            ofDividerAt: 0
        )
        workspaceSplit.splitView.layoutSubtreeIfNeeded()
        lastVisibleAssistantWidth = clampedAssistantWidth(lastVisibleAssistantWidth)
        workspaceSplit.splitView.setPosition(
            workspaceSplit.splitView.bounds.width
                - lastVisibleAssistantWidth
                - workspaceSplit.splitView.dividerThickness,
            ofDividerAt: 1
        )
        editorSplit.splitView.setPosition(
            max(260, editorSplit.splitView.bounds.height - 200 - editorSplit.splitView.dividerThickness),
            ofDividerAt: 0
        )
    }

    private func layoutAutosaveName(_ area: String) -> String {
        let path = root.url.standardizedFileURL.path
        let projectKey = path.data(using: .utf8)?.base64EncodedString() ?? "default"
        return "FSCode.workspace.\(area).\(projectKey)"
    }

    private func clampedAssistantWidth(_ requestedWidth: CGFloat) -> CGFloat {
        let sidebarWidth = max(sidebarItem.minimumThickness, workspaceSplit.splitView.arrangedSubviews.first?.frame.width ?? sidebarItem.minimumThickness)
        let available = workspaceSplit.splitView.bounds.width - sidebarWidth - centerItem.minimumThickness
        let maximum = max(assistantItem.minimumThickness, available)
        return min(max(requestedWidth, assistantItem.minimumThickness), maximum)
    }


    func windowWillClose(_ notification: Notification) {
        workspaceClosed = true
        cancelCapabilityApproval()
        contextRefreshGeneration += 1
        contextResolveGeneration += 1
        contextRefreshTask?.cancel()
        contextResolveTask?.cancel()
        contextWatcher.stop()
        let assistantView = assistantConnectionView
        Task {
            await assistantView.shutdownConversation()
        }
        assistantConnectionView.shutdown()
        saveLayout()
        terminalPane.shutdown()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshAgentContext()
    }

    private func requestProjectCapability(_ request: AgentDynamicToolRequest) async -> AgentDynamicToolResult {
        guard case let .object(arguments) = request.arguments,
              case let .string(capabilityName)? = arguments["capability"],
              case let .bool(enabled)? = arguments["enabled"],
              let capability = ProjectCapability(rawValue: capabilityName) else {
            return .rejected("request_project_capability requires a supported capability and enabled Boolean.")
        }
        let reason: String
        if case let .string(value)? = arguments["reason"] { reason = value } else { reason = "The agent requested this capability." }
        if await capabilityStore.isEnabled(capability) == enabled {
            return .accepted(enabled ? "The project permission is already enabled." : "The project permission is already disabled.")
        }
        if enabled {
            let approved = await confirmCapability(capability, reason: reason)
            guard approved, !Task.isCancelled, !closing else {
                return .rejected("The project permission was not approved.")
            }
        }
        guard !Task.isCancelled, !closing else { return .rejected("The workspace is no longer available.") }
        do {
            try await capabilityStore.setEnabled(capability, enabled: enabled)
            permissionsView.refresh()
            return .accepted(enabled ? "The project permission was enabled." : "The project permission was disabled.")
        } catch {
            return .rejected("The project permission could not be saved.")
        }
    }

    private func confirmCapability(_ capability: ProjectCapability, reason: String) async -> Bool {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, capabilityApprovalContinuation == nil else {
                    continuation.resume(returning: false)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Allow \(capability == .computerUse ? "Computer Use" : "Terminal") in \(window.title)?"
                alert.informativeText = "\(reason)\n\nThis is enabled for agents in this project. Commands run with your macOS account access; Computer Use can interact with other apps."
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Cancel")
                capabilityApprovalContinuation = continuation
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self, let continuation = self.capabilityApprovalContinuation else { return }
                    self.capabilityApprovalContinuation = nil
                    self.capabilityApprovalSheet = nil
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
                capabilityApprovalSheet = alert.window
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelCapabilityApproval() }
        })
    }

    private func cancelCapabilityApproval() {
        if let capabilityApprovalSheet { window.endSheet(capabilityApprovalSheet) }
        guard let continuation = capabilityApprovalContinuation else { return }
        capabilityApprovalContinuation = nil
        capabilityApprovalSheet = nil
        continuation.resume(returning: false)
    }

    var canCloseProject: Bool { !closing && window.attachedSheet == nil && !textEditor.isBusy }

    var canSave: Bool {
        guard !closing, window.attachedSheet == nil else { return false }
        switch projectSidebar.mode {
        case .todos: return projectSidebar.todoDetailView.canSave
        case .plans: return planEditorView.canSave
        case .agentContext: return agentContextView.canSave
        case .files, .permissions: return textEditor.canSave
        }
    }

    var canFind: Bool {
        terminalPane.isTerminalFocused || ((projectSidebar.mode == .files || projectSidebar.mode == .permissions) && textEditor.canFind)
    }
    var isTerminalVisible: Bool { !terminalItem.isCollapsed }
    var canToggleTerminal: Bool { !closing && window.attachedSheet == nil }
    func shutdownTerminal() { terminalPane.shutdown() }

    func saveActive() {
        guard canSave else { return }
        switch projectSidebar.mode {
        case .todos: projectSidebar.todoDetailView.saveChanges()
        case .plans: planEditorView.saveCurrentFromUserAction()
        case .agentContext: agentContextView.saveCurrent()
        case .files, .permissions: Task { await textEditor.saveActive() }
        }
    }

    func findInFile() {
        guard canFind else { return }
        if terminalPane.isTerminalFocused { terminalPane.find() }
        else { textEditor.find() }
    }

    func closeActive() {
        guard !closing, window.attachedSheet == nil, !textEditor.isBusy else { return }
        if projectSidebar.mode == .files && textEditor.hasOpenFiles {
            Task { await textEditor.closeActive() }
        } else { window.performClose(nil) }
    }

    func prepareToClose() async -> Bool {
        guard !closing, window.attachedSheet == nil, !textEditor.isBusy else { return false }
        closing = true
        defer { closing = false }
        guard projectSidebar.todoDetailView.canLeave(),
              await agentContextView.prepareToLeave(),
              await planEditorView.prepareToLeave() else { return false }
        guard await textEditor.prepareToClose() else { return false }
        if terminalPane.hasForegroundJob {
            let alert = NSAlert()
            alert.messageText = "Close project and stop the running command?"
            alert.informativeText = "The command running in this project's terminal will be stopped."
            alert.addButton(withTitle: "Stop and Close")
            alert.addButton(withTitle: "Cancel")
            let shouldStop = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
            guard shouldStop else { return false }
        }
        return await assistantConnectionView.flushConversation()
    }

    func shutdownAssistant() async {
        await assistantConnectionView.shutdownConversation()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        guard !closing else { return false }
        Task { [weak self] in
            guard let self, await self.prepareToClose() else { return }
            self.allowClose = true
            self.window.performClose(nil)
        }
        return false
    }

    func saveLayout() {
        rememberVisiblePaneSizes()
        let layout: [String: Double] = [
            "sidebar": lastVisibleSidebarWidth,
            "assistant": lastVisibleAssistantWidth,
            "terminal": lastVisibleTerminalHeight
        ]
        UserDefaults.standard.set(layout, forKey: layoutAutosaveName("layout"))
    }

    private func rememberVisiblePaneSizes() {
        let workspacePanes = workspaceSplit.splitView.arrangedSubviews
        let editorPanes = editorSplit.splitView.arrangedSubviews
        if !sidebarItem.isCollapsed, workspacePanes.count > 0 { lastVisibleSidebarWidth = workspacePanes[0].frame.width }
        if !assistantItem.isCollapsed, workspacePanes.count > 2 {
            let split = workspaceSplit.splitView
            let trailingEdgeOfDivider = workspacePanes[1].frame.maxX + split.dividerThickness
            lastVisibleAssistantWidth = split.bounds.maxX - trailingEdgeOfDivider
        }
        if !terminalItem.isCollapsed, editorPanes.count > 1 {
            lastVisibleTerminalHeight = editorPanes[1].frame.height
        }
    }


    // MARK: File tree

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root).loadChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root).loadChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingFileSelection else { return }
        openSelectedFile()
    }

    /// Follow the active document without reopening it or moving keyboard focus.
    /// Only its ancestor folders are loaded; this never scans the project recursively.
    private func revealActiveFile(_ url: URL?) {
        synchronizingFileSelection = true
        defer { synchronizingFileSelection = false }
        guard let url else { outline.deselectAll(nil); return }
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if let selected = outline.item(atRow: outline.selectedRow) as? FileNode,
           selected.url.resolvingSymlinksInPath().standardizedFileURL == target {
            return
        }
        // Prefer an existing visible entry, including a symlink to the open file.
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, !node.isDirectory,
               node.url.resolvingSymlinksInPath().standardizedFileURL == target {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
        let rootComponents = root.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = target.pathComponents
        guard components.starts(with: rootComponents), components.count > rootComponents.count else {
            outline.deselectAll(nil)
            return
        }
        var node = root
        for component in components.dropFirst(rootComponents.count) {
            guard let child = node.loadChildren().first(where: { $0.url.lastPathComponent == component }) else {
                outline.deselectAll(nil)
                return
            }
            node = child
            if node.isDirectory { outline.expandItem(node) }
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { outline.deselectAll(nil); return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    @objc private func openSelectedFile() {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory else { return }
        Task { await textEditor.open(node.url) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("file-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        if cell.textField == nil {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let canonicalURL = node.url.resolvingSymlinksInPath().standardizedFileURL
        let isAgentModified = agentModifiedURLs.contains(canonicalURL)
        cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil)
        cell.textField?.stringValue = isAgentModified ? "\(node.url.lastPathComponent) ✦" : node.url.lastPathComponent
        cell.textField?.toolTip = isAgentModified ? "Modified by AI" : nil
        cell.textField?.setAccessibilityValue(isAgentModified ? "Modified by AI" : nil)
        return cell
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarIdentifier, terminalIdentifier, assistantIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, sidebarIdentifier, terminalIdentifier, assistantIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case sidebarIdentifier:
            return toolbarItem(identifier, "Sidebar", "sidebar.left", #selector(toggleSidebar))
        case assistantIdentifier:
            return toolbarItem(identifier, "Assistant", "sidebar.right", #selector(toggleAssistant))
        case terminalIdentifier:
            return toolbarItem(identifier, "Terminal", "rectangle.bottomthird.inset.filled", #selector(toggleTerminal))
        default:
            return nil
        }
    }

    private func toolbarItem(_ identifier: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        return item
    }

    @objc private func toggleSidebar() {
        rememberVisiblePaneSizes()
        sidebarItem.isCollapsed.toggle()
    }
    @objc private func toggleAssistant() {
        rememberVisiblePaneSizes()
        assistantItem.isCollapsed.toggle()
    }
    @objc func toggleTerminal() {
        guard canToggleTerminal else { return }
        let hadFocus = terminalPane.isTerminalFocused
        rememberVisiblePaneSizes()
        terminalItem.isCollapsed.toggle()
        if !terminalItem.isCollapsed {
            window.contentView?.layoutSubtreeIfNeeded()
            if launchesTerminal {
                terminalPane.startIfNeeded()
                terminalPane.focusTerminal()
            }
        } else if hadFocus {
            window.makeFirstResponder(nil)
            if !projectSidebar.showsTodos { textEditor.focusEditor() }
        }
    }

}
