import AppKit
import AgentConnectionCore

@MainActor
final class AssistantChatView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let manager: AgentConversationManager
    private let projectURL: URL
    private let attachmentStore: ChatAttachmentStore?
    private var loadedAttachmentChatID: UUID?
    private let connectionManager: AgentConnectionManager
    var onAddConnection: () -> Void
    var onManageConnections: (NSView) -> Void
    private let selectedProfileID: () -> UUID?
    private let tabStore: AssistantChatTabStore
    private var observerID: UUID?
    private var refreshWork: DispatchWorkItem?
    private var isUpdatingDraft = false
    private var hasLoadedConversation = false
    private var localRecoveryMessage: String?
    private var initialThreadTask: Task<Void, Never>?
    private var agentModifiedPathsObserver: (@MainActor @Sendable (Set<String>) -> Void)?
    private var appliedChangesObserver: (@MainActor @Sendable ([AgentFileChangeRecord]) -> Void)?
    private var onOpenAgentChange: (@MainActor @Sendable (AgentFileChangeHunk) -> Void)?
    private var onOpenProjectFile: (@MainActor @Sendable (String) -> Void)?
    private var renderedAssistantMessages: [UUID: (source: String, phase: ConversationMessagePhase?, rendered: NSAttributedString)] = [:]
    private var renderedTurnFileChanges: [ConversationTurnFileChanges] = []
    private var changedFileHunks: [AgentFileChangeHunk] = []
    private var renderedTabItems: [AssistantChatTabBar.Item] = []
    private var visibleTabIDs: [UUID] = []
    private var renderedMessages: [ConversationMessage] = []
    private var renderedActivities: [ConversationTurnActivitySummary] = []
    private var renderedLiveProgressText: String?
    private var renderedLiveProgressUserMessageID: UUID?
    private var renderedTranscriptWidth: CGFloat?
    private var transcriptRowHeights: [Int: CGFloat] = [:]
    private var transcriptLayoutGeneration = 0
    private var rowMeasurementScheduled = Set<Int>()
    private var visibleMeasurementScheduled = false
    private var followsTranscriptTail = true
    private var isProgrammaticTranscriptScroll = false
    private var pendingTranscriptResizeAnchor: TranscriptViewportAnchor?
    private var transcriptBoundsObserver: NSObjectProtocol?
    private var observedAgentModifiedPaths: Set<String>?
    private var observedAppliedChanges: [AgentFileChangeRecord]?
    private var renderedModels: [ConversationModelOption] = []
    private var renderedSelectedModelID: String?
    private var renderedEfforts: [ConversationReasoningEffort] = []
    private var renderedSelectedEffort: ConversationReasoningEffort?
    private var expandedActivityMessageIDs: Set<UUID> = []
    private var expandedTurnFileIDs: Set<String> = []
    private var usesCompactFooterLayout: Bool?
    private var accountSelectorTitle = "Connect Model"
    private var contextSelectorTitle = "Context —"
    private var accountCompactWidthConstraint: NSLayoutConstraint?
    private var modelCompactWidthConstraint: NSLayoutConstraint?
    private var contextCompactWidthConstraint: NSLayoutConstraint?
    private var renderedQueueState: QueueRenderState?
    private var queueScrollHeightConstraint: NSLayoutConstraint?
    private var pendingTranscriptReveal: (threadID: UUID, profileID: UUID, existingIDs: Set<UUID>, expectedID: UUID?)?
    private var pendingQueueRevealID: UUID?

    private enum TranscriptViewportAnchor {
        case tail
        case message(id: UUID, offset: CGFloat)
    }

    private let tabBar = AssistantChatTabBar()
    private let accountButton = CompactMenuButton()
    private let modeButton = CompactMenuButton()
    private let modelButton = CompactMenuButton()
    private let effortButton = CompactMenuButton()
    private let contextButton = CompactMenuButton()
    private let transcriptTable = NSTableView()
    private let transcriptScrollView = NSScrollView()
    private let composer = ComposerTextView(usingTextLayoutManager: true)
    private let composerScrollView = NSScrollView()
    private let queueContainer = NSStackView()
    private let queueScrollView = NSScrollView()
    private let queueStack = NSStackView()
    private let queueStatus = NSTextField(wrappingLabelWithString: "")
    private let resumeQueueButton = NSButton(title: "Resume", target: nil, action: nil)
    private let attachmentStack = NSStackView()
    private let newChatButton = NSButton(title: "New Chat", target: nil, action: nil)
    private let conversationHistoryButton = NSButton(title: "", target: nil, action: nil)
    private let changeHistoryButton = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let composerContainer = NSView()
    private let footerControls = NSStackView()
    private let connectionRow = NSStackView()
    private let messageRow = NSStackView()

    init(
        manager: AgentConversationManager,
        connectionManager: AgentConnectionManager,
        projectURL: URL,
        selectedProfileID: @escaping () -> UUID?,
        onAddConnection: @escaping () -> Void,
        onManageConnections: @escaping (NSView) -> Void
    ) {
        self.manager = manager
        self.connectionManager = connectionManager
        self.selectedProfileID = selectedProfileID
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.attachmentStore = try? ChatAttachmentStore(projectURL: projectURL)
        tabStore = AssistantChatTabStore(projectURL: projectURL)
        self.onAddConnection = onAddConnection
        self.onManageConnections = onManageConnections
        super.init(frame: .zero)
        buildInterface()
        refreshInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        let viewportAnchor = transcriptViewportAnchor()
        super.layout()
        updateFooterLayout(compact: bounds.width < 560)
        let width = transcriptTable.bounds.width
        if let renderedTranscriptWidth, abs(renderedTranscriptWidth - width) < 0.5 { return }
        renderedTranscriptWidth = width
        transcriptLayoutGeneration &+= 1
        guard transcriptTable.numberOfRows > 0 else { return }
        pendingTranscriptResizeAnchor = viewportAnchor
        scheduleVisibleRowMeasurements()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTranscriptScrollObserver()
        guard window != nil, observerID == nil else { return }
        observerID = manager.addObserver { [weak self] in
            self?.scheduleRefresh()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.load()
                self.hasLoadedConversation = true
                self.ensureInitialChatIfNeeded()
                self.refreshInterface()
            } catch {
                self.showRecovery("Unable to load saved chats. Try again.")
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            detach()
        }
    }

    func detach() {
        refreshWork?.cancel()
        refreshWork = nil
        initialThreadTask?.cancel()
        initialThreadTask = nil
        if let observerID {
            manager.removeObserver(observerID)
            self.observerID = nil
        }
        if let transcriptBoundsObserver {
            NotificationCenter.default.removeObserver(transcriptBoundsObserver)
            self.transcriptBoundsObserver = nil
        }
    }

    /// Row fitting and programmatic tail reveals also move the clip view.  Those
    /// geometry changes are not user intent, so only AppKit's live-scroll event
    /// is allowed to opt out of following a streaming response.
    private func installTranscriptScrollObserver() {
        guard transcriptBoundsObserver == nil else { return }
        transcriptBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: transcriptScrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isProgrammaticTranscriptScroll else { return }
                self.followsTranscriptTail = self.isNearTranscriptEnd
            }
        }
    }

    func flushConversation() async throws {
        guard hasLoadedConversation else { return }
        try await manager.flush()
    }

    func shutdownConversation() async throws {
        detach()
        try await manager.shutdown()
    }

    func executePlan(planID: String) async throws {
        guard manager.selectedThreadID != nil else {
            throw AgentConnectionError.unavailable("Create or select a chat before running a plan.")
        }
        try await manager.executePlan(planID: planID)
    }

    func configureFileMutationHandlers(
        authorize: @escaping @MainActor @Sendable (String, ConversationFileMutationOperation) async -> Bool,
        didComplete: @escaping @MainActor @Sendable (ConversationFileMutationResult) -> Void
    ) {
        manager.authorizeFileMutation = authorize
        manager.didCompleteFileMutation = didComplete
    }

    func configureAgentModifiedPathsObserver(
        _ observer: @escaping @MainActor @Sendable (Set<String>) -> Void
    ) {
        agentModifiedPathsObserver = observer
        observer(manager.agentModifiedPaths)
    }

    func configureAppliedChangesObserver(
        _ observer: @escaping @MainActor @Sendable ([AgentFileChangeRecord]) -> Void
    ) {
        appliedChangesObserver = observer
        observer(manager.appliedChanges)
    }

    func configureAgentChangeOpenHandler(
        _ handler: @escaping @MainActor @Sendable (AgentFileChangeHunk) -> Void
    ) {
        onOpenAgentChange = handler
    }

    func configureProjectFileOpenHandler(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        onOpenProjectFile = handler
    }

    func revertAgentChange(_ hunk: AgentFileChangeHunk) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.revertChangeHunk(recordID: hunk.recordID, hunkID: hunk.id)
            } catch {
                self.showRecovery(error.localizedDescription)
            }
        }
    }

    private func buildInterface() {
        wantsLayer = true
        updateSurfaceColors()
        configureMenuButton(accountButton, icon: "person.crop.circle", accessibilityLabel: "Connection", action: #selector(showAccounts))
        configureMenuButton(modeButton, icon: "chevron.down", accessibilityLabel: "Agent mode", action: #selector(showModes))
        configureMenuButton(modelButton, icon: "chevron.down", accessibilityLabel: "Chat model", action: #selector(showModels))
        configureMenuButton(effortButton, icon: "chevron.down", accessibilityLabel: "Reasoning effort", action: #selector(showEfforts))
        configureMenuButton(contextButton, icon: "circle.dotted", accessibilityLabel: "Last request input context", action: #selector(showContextUsage))
        configureSymbolButton(newChatButton, symbol: "plus", accessibilityLabel: "New chat", action: #selector(createChat))
        configureSymbolButton(
            conversationHistoryButton,
            symbol: "clock.arrow.circlepath",
            accessibilityLabel: "Reopen chat",
            action: #selector(showConversationHistory)
        )
        conversationHistoryButton.toolTip = "Reopen a closed chat"
        for button in [newChatButton, conversationHistoryButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .small
        }
        configureSymbolButton(
            changeHistoryButton,
            symbol: "clock.arrow.circlepath",
            accessibilityLabel: "Change history",
            action: #selector(showChangeHistory)
        )
        changeHistoryButton.toolTip = "Change history"
        configureSymbolButton(sendButton, symbol: "arrow.up.circle.fill", accessibilityLabel: "Send message", action: #selector(sendMessage))
        configureSymbolButton(stopButton, symbol: "stop.circle.fill", accessibilityLabel: "Stop response", action: #selector(stopResponse))
        for button in [changeHistoryButton, stopButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .small
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        transcriptTable.addTableColumn(column)
        transcriptTable.headerView = nil
        transcriptTable.dataSource = self
        transcriptTable.delegate = self
        transcriptTable.usesAutomaticRowHeights = false
        transcriptTable.rowHeight = 52
        transcriptTable.selectionHighlightStyle = .none
        transcriptTable.backgroundColor = .clear
        transcriptTable.setAccessibilityLabel("Chat transcript")
        transcriptScrollView.documentView = transcriptTable
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.contentView.drawsBackground = false
        installTranscriptScrollObserver()
        transcriptScrollView.backgroundColor = .clear

        composer.isRichText = false
        composer.font = .systemFont(ofSize: 14)
        composer.textContainerInset = NSSize(width: 8, height: 7)
        composer.minSize = NSSize(width: 0, height: 0)
        composer.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        composer.delegate = self
        composer.drawsBackground = false
        composer.placeholder = "Message · Enter to send"
        composer.onCommandReturn = { [weak self] in self?.sendMessage() }
        composer.onFileDrop = { [weak self] urls in self?.attachDroppedFiles(urls) }
        composer.registerForDraggedTypes([.fileURL])
        composer.setAccessibilityLabel("Message composer")
        composer.setAccessibilityHelp("Enter to send. Shift-Enter inserts a new line.")
        composerScrollView.documentView = composer
        composerScrollView.hasVerticalScroller = true
        composerScrollView.scrollerStyle = .overlay
        composerScrollView.autohidesScrollers = true
        composerScrollView.borderType = .noBorder
        composerScrollView.drawsBackground = false

        queueStack.orientation = .vertical
        queueStack.alignment = .leading
        queueStack.spacing = 3
        queueStack.translatesAutoresizingMaskIntoConstraints = false
        queueScrollView.documentView = queueStack
        queueScrollView.hasVerticalScroller = true
        queueScrollView.scrollerStyle = .overlay
        queueScrollView.autohidesScrollers = true
        queueScrollView.drawsBackground = false
        queueScrollView.borderType = .noBorder
        queueScrollHeightConstraint = queueScrollView.heightAnchor.constraint(equalToConstant: 0)
        queueScrollHeightConstraint?.isActive = true
        queueStatus.font = .systemFont(ofSize: 11)
        queueStatus.textColor = .secondaryLabelColor
        queueStatus.maximumNumberOfLines = 2
        resumeQueueButton.bezelStyle = .inline
        resumeQueueButton.isBordered = false
        resumeQueueButton.controlSize = .small
        resumeQueueButton.target = self
        resumeQueueButton.action = #selector(resumeQueue)
        resumeQueueButton.setAccessibilityLabel("Resume queued messages")
        let queueHeader = NSStackView(views: [queueStatus, NSView(), resumeQueueButton])
        queueHeader.orientation = .horizontal
        queueHeader.alignment = .centerY
        queueHeader.spacing = 5
        queueContainer.setViews([queueHeader, queueScrollView], in: .leading)
        queueContainer.orientation = .vertical
        queueContainer.alignment = .leading
        queueContainer.spacing = 3
        queueContainer.isHidden = true
        queueHeader.translatesAutoresizingMaskIntoConstraints = false
        queueScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            queueStack.widthAnchor.constraint(equalTo: queueScrollView.contentView.widthAnchor),
            queueHeader.widthAnchor.constraint(equalTo: queueContainer.widthAnchor),
            queueScrollView.widthAnchor.constraint(equalTo: queueContainer.widthAnchor)
        ])

        attachmentStack.orientation = .horizontal
        attachmentStack.alignment = .centerY
        attachmentStack.spacing = 4
        attachmentStack.isHidden = true

        tabBar.onSelect = { [weak self] id in self?.selectChat(id) }
        tabBar.onClose = { [weak self] id in self?.closeChat(id) }
        tabBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        let chatHeader = NSStackView(views: [
            tabBar, headerSpacer, newChatButton, conversationHistoryButton
        ])
        chatHeader.orientation = .horizontal
        chatHeader.alignment = .centerY
        chatHeader.spacing = 4
        newChatButton.toolTip = "New chat"
        let connectionSpacer = NSView()
        connectionSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        connectionRow.setViews([accountButton, connectionSpacer, contextButton], in: .leading)
        connectionRow.orientation = .horizontal
        connectionRow.alignment = .centerY
        connectionRow.spacing = 6

        let messageSpacer = NSView()
        messageSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        messageRow.setViews([modeButton, modelButton, effortButton, messageSpacer, changeHistoryButton, stopButton, sendButton], in: .leading)
        messageRow.orientation = .horizontal
        messageRow.alignment = .centerY
        messageRow.spacing = 6
        modelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        modelCompactWidthConstraint = modelButton.widthAnchor.constraint(lessThanOrEqualToConstant: 104)
        effortButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        effortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        effortButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        modelButton.imagePosition = .imageTrailing
        effortButton.imagePosition = .imageTrailing
        accountCompactWidthConstraint = accountButton.widthAnchor.constraint(equalToConstant: 24)
        contextCompactWidthConstraint = contextButton.widthAnchor.constraint(equalToConstant: 24)
        modeButton.imagePosition = .imageTrailing
        modeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        for button in [accountButton, modeButton, modelButton, effortButton, contextButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        }

        footerControls.setViews([connectionRow], in: .leading)
        footerControls.orientation = .vertical
        footerControls.alignment = .leading
        footerControls.spacing = 4
        for row in [connectionRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: footerControls.widthAnchor).isActive = true
        }

        composerContainer.wantsLayer = true
        composerContainer.layer?.cornerRadius = 12
        composerContainer.layer?.cornerCurve = .continuous
        composerContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        composerContainer.layer?.borderWidth = 1
        composerContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        composerContainer.addSubview(attachmentStack)
        composerContainer.addSubview(composerScrollView)
        composerContainer.addSubview(footerControls)
        composerScrollView.translatesAutoresizingMaskIntoConstraints = false
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        footerControls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            composerScrollView.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 8),
            composerScrollView.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -8),
            attachmentStack.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 12),
            attachmentStack.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -12),
            attachmentStack.topAnchor.constraint(equalTo: composerContainer.topAnchor, constant: 6),
            composerScrollView.topAnchor.constraint(equalTo: attachmentStack.bottomAnchor, constant: 4),
            composerScrollView.heightAnchor.constraint(equalToConstant: 48),
            footerControls.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 8),
            footerControls.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -8),
            footerControls.topAnchor.constraint(equalTo: composerScrollView.bottomAnchor, constant: 7),
            footerControls.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -8)
        ])

        let content = NSStackView(views: [
            chatHeader, statusLabel,
            transcriptScrollView, queueContainer, composerContainer
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        for view in [chatHeader, statusLabel, transcriptScrollView, queueContainer, composerContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            chatHeader.heightAnchor.constraint(equalToConstant: 30)
        ])
        updateFooterLayout(compact: true)
    }

    private func updateFooterLayout(compact: Bool) {
        guard usesCompactFooterLayout != compact else { return }
        usesCompactFooterLayout = compact
        connectionRow.arrangedSubviews.forEach { connectionRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        messageRow.arrangedSubviews.forEach { messageRow.removeArrangedSubview($0); $0.removeFromSuperview() }

        let firstSpacer = NSView()
        firstSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        connectionRow.addArrangedSubview(accountButton)
        connectionRow.addArrangedSubview(modeButton)
        connectionRow.addArrangedSubview(modelButton)
        connectionRow.addArrangedSubview(effortButton)
        connectionRow.addArrangedSubview(firstSpacer)
        connectionRow.addArrangedSubview(contextButton)
        connectionRow.addArrangedSubview(changeHistoryButton)
        connectionRow.addArrangedSubview(stopButton)
        connectionRow.addArrangedSubview(sendButton)
        messageRow.isHidden = true
        footerControls.spacing = 0
        updateInlineSelectorPresentation(compact: compact)
    }

    private func updateInlineSelectorPresentation(compact: Bool) {
        if let usage = manager.lastRequestInputContext {
            let percent = Int(min(100, max(0, (usage.utilization * 100).rounded())))
            contextSelectorTitle = compact ? "\(percent)%" : "Context \(percent)%"
        } else {
            contextSelectorTitle = compact ? "—" : "Context —"
        }
        accountCompactWidthConstraint?.isActive = compact
        modelCompactWidthConstraint?.isActive = compact
        contextCompactWidthConstraint?.isActive = compact
        accountButton.title = compact ? "" : accountSelectorTitle
        contextButton.title = compact ? "" : contextSelectorTitle
    }

    private func configureMenuButton(_ button: CompactMenuButton, icon: String, accessibilityLabel: String, action: Selector) {
        button.title = accessibilityLabel
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: accessibilityLabel)
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func configureSymbolButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        configureButton(button, action: action)
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 2
        return field
    }

    private func scheduleRefresh() {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refreshInterface()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }

    private var isBusy: Bool {
        manager.hasActiveTurn
    }

    private var isConnected: Bool {
        if case .connected = manager.connectionState { return true }
        return false
    }

    private var canCompose: Bool {
        isConnected && manager.selectedThreadID != nil && !isBusy
    }

    private var canEditDraft: Bool {
        isConnected && manager.selectedThreadID != nil
    }

    private func refreshInterface() {
        ensureInitialChatIfNeeded()
        let selectedProfile = connectionManager.profiles.first { $0.id == connectionManager.selectedProfileID }
        let connectedAccountName: String?
        if case .connected(let accountName) = manager.connectionState {
            connectedAccountName = accountName
        } else {
            connectedAccountName = nil
        }
        accountSelectorTitle = selectedProfile?.name ?? connectedAccountName ?? "Connect Model"
        accountButton.toolTip = accountSelectorTitle
        accountButton.isEnabled = !isBusy
        if let usage = manager.lastRequestInputContext {
            let percent = Int(min(100, max(0, (usage.utilization * 100).rounded())))
            contextSelectorTitle = usesCompactFooterLayout == true ? "\(percent)%" : "Context \(percent)%"
            contextButton.image = contextIcon(utilization: usage.utilization)
            contextButton.toolTip = "Last request input context: \(usage.inputTokens) of \(usage.modelContextWindow) tokens"
            contextButton.setAccessibilityValue("\(percent)%")
        } else {
            contextSelectorTitle = usesCompactFooterLayout == true ? "—" : "Context —"
            contextButton.image = contextIcon(utilization: nil)
            contextButton.toolTip = "Last request input context is not reported"
            contextButton.setAccessibilityValue("Unavailable")
        }
        updateInlineSelectorPresentation(compact: usesCompactFooterLayout ?? true)
        if observedAgentModifiedPaths != manager.agentModifiedPaths {
            observedAgentModifiedPaths = manager.agentModifiedPaths
            agentModifiedPathsObserver?(manager.agentModifiedPaths)
        }
        if observedAppliedChanges != manager.appliedChanges {
            observedAppliedChanges = manager.appliedChanges
            appliedChangesObserver?(manager.appliedChanges)
        }
        let messageIDs = Set(manager.messages.map(\.id))
        renderedAssistantMessages = renderedAssistantMessages.filter { messageIDs.contains($0.key) }
        let shouldScrollToEnd = isNearTranscriptEnd
        if shouldScrollToEnd { followsTranscriptTail = true }
        configureTabs()
        configureChangeHistory()
        configureChangedFiles()
        let selectedModel = configureModels()
        configureMode()
        configureEfforts(for: selectedModel)
        updateComposerState()
        configureQueue()
        let hidesIdleStatus = localRecoveryMessage == nil &&
            (manager.activity == .idle || manager.liveProgressText?.isEmpty == false)
        statusLabel.isHidden = hidesIdleStatus
        if !hidesIdleStatus {
            statusLabel.stringValue = localRecoveryMessage ?? manager.activity.statusText
            statusLabel.textColor = statusColor
        }
        refreshTranscript()
        revealPendingSubmissionIfNeeded()
        if shouldScrollToEnd, transcriptTable.numberOfRows > 0 {
            scrollTranscriptToRow(transcriptTable.numberOfRows - 1)
        }
    }

    private func ensureInitialChatIfNeeded() {
        guard hasLoadedConversation,
              manager.selectedThreadID == nil,
              initialThreadTask == nil,
              isConnected else { return }
        initialThreadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.manager.ensureInitialThread()
            self.initialThreadTask = nil
        }
    }

    private func configureChangedFiles() {
        let turnFileChanges = manager.turnFileChanges
        guard turnFileChanges != renderedTurnFileChanges else { return }
        renderedTurnFileChanges = turnFileChanges
        // File changes alter controls embedded in assistant rows without changing message text.
        renderedMessages = []
        let hunks = turnFileChanges
            .flatMap(\.records)
            .filter { $0.status != .reverted }
            .flatMap(\.changeHunks)
            .filter { !$0.isReverted }
        changedFileHunks = hunks
    }

    private func changeLocationTitle(for hunk: AgentFileChangeHunk) -> String {
        let count = max(1, hunk.afterLineCount)
        let lines = count == 1
            ? "line \(hunk.newStartLine)"
            : "lines \(hunk.newStartLine)-\(hunk.newStartLine + count - 1)"
        return "\(hunk.relativePath) · \(lines)"
    }

    private func configureChangeHistory() {
        changeHistoryButton.isHidden = availableReverts.isEmpty
    }

    private var availableReverts: [AgentFileChangeRecord] {
        Array(manager.appliedChanges.filter { $0.status == .applied }.prefix(20))
    }

    private func configureTabs() {
        guard let profileID = selectedProfileID(), !manager.threads.isEmpty else {
            visibleTabIDs = []
            if !renderedTabItems.isEmpty {
                renderedTabItems = []
                tabBar.update(items: [])
            }
            newChatButton.isEnabled = isConnected && !isBusy
            conversationHistoryButton.isEnabled = false
            return
        }

        let available = manager.threads.map(\.id)
        let storedState = tabStore.state(for: profileID)
        let state = AssistantChatTabState.reconciled(
            stored: storedState,
            availableThreadIDs: available,
            selectedThreadID: manager.selectedThreadID
        )
        visibleTabIDs = state.openThreadIDs
        if state != storedState {
            tabStore.save(state, for: profileID)
        }

        let items = state.openThreadIDs.compactMap { id -> AssistantChatTabBar.Item? in
            guard let thread = manager.threads.first(where: { $0.id == id }) else { return nil }
            let isSelected = id == manager.selectedThreadID
            let isLastOpenTab = state.openThreadIDs.count == 1
            let closeToolTip: String
            if isBusy && isSelected {
                closeToolTip = "Stop the response before closing this chat tab"
            } else if isLastOpenTab {
                closeToolTip = "Keep one chat tab open"
            } else {
                closeToolTip = "Close tab without deleting this chat"
            }
            return AssistantChatTabBar.Item(
                id: id,
                title: thread.title,
                isSelected: isSelected,
                canSelect: !isBusy || isSelected,
                canClose: !(isBusy && isSelected) && !isLastOpenTab,
                closeToolTip: closeToolTip
            )
        }
        if items != renderedTabItems {
            renderedTabItems = items
            tabBar.update(items: items)
        }
        newChatButton.isEnabled = isConnected && !isBusy
        conversationHistoryButton.isEnabled = manager.threads.contains { !state.openThreadIDs.contains($0.id) } && !isBusy
    }

    @discardableResult
    private func configureModels() -> ConversationModelOption? {
        let models = manager.models
        let model = models.first { $0.id == manager.selectedModelID }
            ?? models.first(where: \.isDefault)
            ?? models.first
        if renderedModels != models || renderedSelectedModelID != model?.id {
            renderedModels = models
            renderedSelectedModelID = model?.id
        }
        modelButton.title = model?.displayName ?? "Model"
        modelButton.toolTip = model?.displayName ?? "Model"
        modelButton.isEnabled = canCompose && !models.isEmpty
        return model
    }

    private func configureEfforts(for model: ConversationModelOption?) {
        let availableEfforts = model?.supportedEfforts ?? []
        let selectedEffort = availableEfforts.first { $0 == manager.selectedEffort }
            ?? model?.defaultEffort
            ?? availableEfforts.first
        if renderedEfforts != availableEfforts || renderedSelectedEffort != selectedEffort {
            renderedEfforts = availableEfforts
            renderedSelectedEffort = selectedEffort
        }
        effortButton.title = selectedEffort.map(effortDisplayName) ?? "Reasoning"
        effortButton.toolTip = selectedEffort.map(effortDisplayName) ?? "Reasoning"
        effortButton.isEnabled = canCompose && !availableEfforts.isEmpty
    }

    private func configureMode() {
        let mode = manager.mode
        modeButton.title = modeDisplayName(mode)
        modeButton.toolTip = "Agent mode: \(modeDisplayName(mode))"
        modeButton.setAccessibilityValue(modeDisplayName(mode))
        modeButton.isEnabled = manager.selectedThreadID != nil && !isBusy && manager.queuedMessages.isEmpty
    }

    private func updateComposerState() {
        isUpdatingDraft = true
        let visibleDraft = visibleMessageText(manager.draft)
        if composer.string != visibleDraft {
            composer.string = visibleDraft
        }
        isUpdatingDraft = false
        composer.isEditable = canEditDraft
        composer.placeholder = isConnected
            ? (manager.selectedThreadID == nil ? "Create a chat to begin" : "Message · Enter to send")
            : "Connect a model to start a chat"
        composer.needsDisplay = true
        loadAttachmentsForSelectedChat()
        configureAttachmentChips()
        let queuesMessage = isBusy
        sendButton.isEnabled = manager.canSend || manager.canQueue
        sendButton.setAccessibilityLabel(queuesMessage ? "Queue message" : "Send message")
        sendButton.toolTip = queuesMessage ? "Queue message" : "Send message"
        stopButton.isHidden = !isBusy
        stopButton.isEnabled = isBusy
    }

    private func configureQueue() {
        let queued = manager.queuedMessages
        let state = QueueRenderState(
            messages: queued,
            isPaused: manager.queueIsPaused,
            error: manager.queueError,
            canSteer: manager.canSteer,
            inFlightID: manager.queuedMessageInFlightID,
            isConnected: isConnected
        )
        if state == renderedQueueState {
            revealPendingQueueIfNeeded()
            return
        }
        renderedQueueState = state
        queueStack.arrangedSubviews.forEach { queueStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for message in queued {
            let text = NSTextField(labelWithString: message.text)
            text.font = .systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = 1
            text.toolTip = message.text
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.setAccessibilityLabel("Queued message")

            let steer = QueuedMessageButton(messageID: message.id)
            steer.title = "Steer"
            steer.bezelStyle = .inline
            steer.isBordered = false
            steer.controlSize = .small
            steer.target = self
            steer.action = #selector(steerQueuedMessage(_:))
            steer.setAccessibilityLabel("Steer queued message")

            let remove = QueuedMessageButton(messageID: message.id)
            remove.title = ""
            remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove queued message")
            remove.imagePosition = .imageOnly
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.controlSize = .small
            remove.target = self
            remove.action = #selector(removeQueuedMessage(_:))
            remove.setAccessibilityLabel("Remove queued message")

            let isInFlight = manager.queuedMessageInFlightID == message.id
            steer.isEnabled = manager.canSteer && !isInFlight
            remove.isEnabled = !isInFlight
            let row = NSStackView(views: [text, steer, remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            text.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -86).isActive = true
            queueStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: queueStack.widthAnchor).isActive = true
        }

        if let error = manager.queueError, !error.isEmpty {
            queueStatus.stringValue = error
            queueStatus.textColor = .systemRed
        } else if manager.queueIsPaused {
            queueStatus.stringValue = queued.isEmpty ? "Queue paused" : "Queued messages paused"
            queueStatus.textColor = .secondaryLabelColor
        } else {
            queueStatus.stringValue = queued.count == 1 ? "1 queued message" : "\(queued.count) queued messages"
            queueStatus.textColor = .secondaryLabelColor
        }
        resumeQueueButton.isHidden = !manager.queueIsPaused
        resumeQueueButton.isEnabled = manager.queueIsPaused && isConnected
        queueScrollView.isHidden = queued.isEmpty
        let rowHeight = CGFloat(24)
        let spacing = CGFloat(max(0, queued.count - 1) * 3)
        queueScrollHeightConstraint?.constant = min(94, CGFloat(queued.count) * rowHeight + spacing)
        queueContainer.isHidden = queued.isEmpty && !manager.queueIsPaused && manager.queueError == nil
        revealPendingQueueIfNeeded()
    }

    private func revealPendingQueueIfNeeded() {
        guard let messageID = pendingQueueRevealID else { return }
        layoutSubtreeIfNeeded()
        guard let button = descendants(in: queueStack, matching: messageID) else { return }
        pendingQueueRevealID = nil
        guard let row = button.superview else { return }
        row.scrollToVisible(row.bounds)
    }

    private func descendants(in view: NSView, matching messageID: UUID) -> QueuedMessageButton? {
        if let button = view as? QueuedMessageButton, button.messageID == messageID { return button }
        return view.subviews.lazy.compactMap { self.descendants(in: $0, matching: messageID) }.first
    }

    private func revealPendingSubmissionIfNeeded() {
        guard let pending = pendingTranscriptReveal else { return }
        guard selectedProfileID() == pending.profileID, manager.selectedThreadID == pending.threadID else {
            pendingTranscriptReveal = nil
            return
        }
        guard let row = manager.messages.lastIndex(where: {
            $0.role == .user && !pending.existingIDs.contains($0.id) && (pending.expectedID == nil || $0.id == pending.expectedID)
        }) else { return }
        pendingTranscriptReveal = nil
        let messageID = manager.messages[row].id
        DispatchQueue.main.async { [weak self] in
            self?.revealTranscriptRow(
                row,
                messageID: messageID,
                threadID: pending.threadID,
                profileID: pending.profileID,
                remainingLayoutPasses: 2
            )
        }
    }

    private func revealTranscriptRow(
        _ row: Int,
        messageID: UUID,
        threadID: UUID,
        profileID: UUID,
        remainingLayoutPasses: Int
    ) {
        guard selectedProfileID() == profileID,
              manager.selectedThreadID == threadID,
              manager.messages.indices.contains(row),
              manager.messages[row].id == messageID else { return }
        layoutSubtreeIfNeeded()
        transcriptTable.noteNumberOfRowsChanged()
        followsTranscriptTail = true
        scrollTranscriptToRow(row)
        guard remainingLayoutPasses > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            let rowRect = self.transcriptTable.rect(ofRow: row)
            let isVisible = rowRect.height <= self.transcriptTable.visibleRect.height
                ? self.transcriptTable.visibleRect.contains(rowRect)
                : self.transcriptTable.visibleRect.intersects(rowRect)
            guard !isVisible else { return }
            self.revealTranscriptRow(
                row,
                messageID: messageID,
                threadID: threadID,
                profileID: profileID,
                remainingLayoutPasses: remainingLayoutPasses - 1
            )
        }
    }

    private var isNearTranscriptEnd: Bool {
        guard let documentView = transcriptScrollView.documentView else { return true }
        return documentView.bounds.height - transcriptScrollView.contentView.bounds.maxY < 48
    }

    private var statusColor: NSColor {
        if localRecoveryMessage != nil { return .systemRed }
        switch manager.activity {
        case .failed: return .systemRed
        case .starting, .responding, .stopping: return .systemOrange
        case .idle: return .secondaryLabelColor
        }
    }

    private func contextIcon(utilization: Double?) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 5
            let background = NSBezierPath()
            background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            background.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            background.stroke()
            if let utilization {
                let progress = min(1, max(0, utilization))
                let foreground = NSBezierPath()
                foreground.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - CGFloat(progress * 360),
                    clockwise: true
                )
                foreground.lineWidth = 2
                foreground.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                foreground.stroke()
            } else {
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
                NSColor.secondaryLabelColor.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = utilization == nil ? "Context usage unavailable" : "Context usage"
        return image
    }

    private func selectChat(_ id: UUID) {
        guard !isBusy, id != manager.selectedThreadID else { return }
        Task { await manager.selectThread(id: id) }
    }

    private func closeChat(_ id: UUID) {
        guard let profileID = selectedProfileID(),
              visibleTabIDs.count > 1,
              !(isBusy && id == manager.selectedThreadID) else { return }

        if id != manager.selectedThreadID {
            persistTabs(visibleTabIDs.filter { $0 != id }, profileID: profileID)
            refreshInterface()
            return
        }

        guard let nextID = visibleTabIDs.first(where: { $0 != id }) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.manager.selectThread(id: nextID)
            self.persistTabs(self.visibleTabIDs.filter { $0 != id }, profileID: profileID)
            self.refreshInterface()
        }
    }

    private func persistTabs(_ ids: [UUID], profileID: UUID) {
        visibleTabIDs = ids
        tabStore.save(
            AssistantChatTabState(openThreadIDs: ids, selectedThreadID: manager.selectedThreadID),
            for: profileID
        )
    }

    @objc private func createChat() {
        localRecoveryMessage = nil
        Task {
            do {
                _ = try await manager.newThread()
            } catch {
                showRecovery("Unable to start a chat. Check the connection and try again.")
            }
        }
    }

    @objc private func showConversationHistory() {
        let open = Set(visibleTabIDs)
        let menu = NSMenu()
        for thread in manager.threads where !open.contains(thread.id) {
            let item = menu.addItem(withTitle: thread.title, action: #selector(reopenChat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = thread.id
        }
        guard menu.items.isEmpty == false else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: conversationHistoryButton.bounds.height),
            in: conversationHistoryButton
        )
    }

    @objc private func reopenChat(_ sender: NSMenuItem) {
        guard !isBusy,
              let profileID = selectedProfileID(),
              let id = sender.representedObject as? UUID,
              manager.threads.contains(where: { $0.id == id }) else { return }
        persistTabs(visibleTabIDs + [id], profileID: profileID)
        selectChat(id)
        refreshInterface()
    }

    @objc private func showChangeHistory() {
        let menu = NSMenu()
        for change in availableReverts {
            let item = menu.addItem(
                withTitle: "Revert \(change.relativePath)",
                action: #selector(revertChange(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = change.id
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: changeHistoryButton.bounds.height),
            in: changeHistoryButton
        )
    }

    @objc private func revertChange(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.revertAppliedChange(id: id)
            } catch {
                self.showRecovery(error.localizedDescription)
            }
        }
    }

    @objc private func openAgentChange(_ sender: NSButton) {
        guard let button = sender as? AgentChangeOpenButton else { return }
        onOpenAgentChange?(button.hunk)
    }

    @objc private func showMoreChangedFiles(_ sender: NSButton) {
        let menu = NSMenu()
        for hunk in changedFileHunks.dropFirst(4) {
            let item = menu.addItem(
                withTitle: changeLocationTitle(for: hunk),
                action: #selector(openAgentChangeMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = hunk
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func openAgentChangeMenuItem(_ sender: NSMenuItem) {
        guard let hunk = sender.representedObject as? AgentFileChangeHunk else { return }
        onOpenAgentChange?(hunk)
    }

    @objc private func showModels() {
        let menu = NSMenu()
        for model in manager.models {
            let item = menu.addItem(withTitle: model.displayName, action: #selector(changeModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == manager.selectedModelID ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.height), in: modelButton)
    }

    @objc private func showModes() {
        let menu = NSMenu()
        for mode in AgentMode.allCases {
            let item = menu.addItem(withTitle: modeDisplayName(mode), action: #selector(changeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == manager.mode ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modeButton.bounds.height), in: modeButton)
    }

    @objc private func changeMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AgentMode(rawValue: rawValue),
              mode != manager.mode,
              !isBusy,
              manager.queuedMessages.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.setMode(mode)
            } catch {
                self.showRecovery(error.localizedDescription)
            }
        }
    }

    private func modeDisplayName(_ mode: AgentMode) -> String {
        mode.rawValue.capitalized
    }

    @objc private func changeModel(_ sender: NSMenuItem) {
        let modelID = sender.representedObject as? String
        Task {
            do {
                try await manager.selectModel(id: modelID)
            } catch {
                showRecovery("Unable to select that model. Refresh the connection and try again.")
            }
        }
    }

    @objc private func showEfforts() {
        let model = manager.models.first { $0.id == manager.selectedModelID } ?? manager.models.first
        let menu = NSMenu()
        for effort in model?.supportedEfforts ?? [] {
            let item = menu.addItem(withTitle: effortDisplayName(effort), action: #selector(changeEffort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effort.rawValue
            item.state = effort == manager.selectedEffort ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: effortButton.bounds.height), in: effortButton)
    }

    @objc private func changeEffort(_ sender: NSMenuItem) {
        let rawValue = sender.representedObject as? String
        let effort = rawValue.flatMap(ConversationReasoningEffort.init(rawValue:))
        Task {
            do {
                try await manager.selectEffort(effort)
            } catch {
                showRecovery("That reasoning level is not available for this model.")
            }
        }
    }

    private func effortDisplayName(_ effort: ConversationReasoningEffort) -> String {
        effort.rawValue.lowercased() == "xhigh" ? "Extra High" : effort.rawValue.capitalized
    }

    @objc private func showAccounts() {
        let menu = NSMenu()
        for profile in connectionManager.profiles {
            let item = menu.addItem(withTitle: profile.name, action: #selector(changeAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == connectionManager.selectedProfileID ? .on : .off
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "Connect Model…", action: #selector(addAccount), keyEquivalent: "")
        add.target = self
        let manage = menu.addItem(withTitle: "Manage Connections…", action: #selector(manageAccounts), keyEquivalent: "")
        manage.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: accountButton.bounds.height), in: accountButton)
    }

    @objc private func changeAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, !isBusy else { return }
        Task { await connectionManager.selectProfile(id: id) }
    }

    @objc private func addAccount() { onAddConnection() }

    @objc private func manageAccounts() { onManageConnections(accountButton) }

    @objc private func showContextUsage() {
        let menu = NSMenu()
        if let usage = manager.lastRequestInputContext {
            menu.addItem(
                withTitle: "Last request input context: \(usage.inputTokens) of \(usage.modelContextWindow) tokens",
                action: nil,
                keyEquivalent: ""
            )
        } else {
            menu.addItem(withTitle: "Last request input context is not reported", action: nil, keyEquivalent: "")
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: contextButton.bounds.height), in: contextButton)
    }

    @objc private func sendMessage() {
        guard manager.canSend || (isBusy && manager.canQueue) else { return }
        guard let attachmentChatID = manager.selectedThreadID else { return }
        let originalDraft = manager.draft
        let attachmentPayload: String
        do { attachmentPayload = try attachmentStore?.renderedPayload(chatID: attachmentChatID) ?? "" }
        catch { presentAttachmentError(error.localizedDescription); return }
        let submittedDraft = attachmentPayload.isEmpty ? originalDraft : originalDraft + "\n\n<fs_code_attachments>\n" + attachmentPayload + "\n</fs_code_attachments>"
        if submittedDraft != originalDraft { manager.updateDraft(submittedDraft) }
        window?.makeFirstResponder(composer)
        localRecoveryMessage = nil
        let threadID = manager.selectedThreadID
        let profileID = selectedProfileID()
        let queuesMessage = isBusy
        let existingIDs = Set(manager.messages.map(\.id))
        let existingQueueIDs = Set(manager.queuedMessages.map(\.id))
        Task { [weak self] in
            guard let self else { return }
            guard self.selectedProfileID() == profileID, self.manager.selectedThreadID == threadID else {
                self.pendingTranscriptReveal = nil
                return
            }
            await self.manager.send()
            guard self.selectedProfileID() == profileID, self.manager.selectedThreadID == threadID else { return }
            if queuesMessage, let queuedID = self.manager.queuedMessages.last(where: { !existingQueueIDs.contains($0.id) })?.id {
                self.clearAttachmentsAfterAcceptance(chatID: attachmentChatID)
                self.pendingQueueRevealID = queuedID
                self.configureQueue()
            } else if !queuesMessage,
                      self.manager.messages.contains(where: { $0.role == .user && !existingIDs.contains($0.id) }) {
                self.clearAttachmentsAfterAcceptance(chatID: attachmentChatID)
            } else {
                self.pendingTranscriptReveal = nil
                if self.manager.draft == submittedDraft { self.manager.updateDraft(originalDraft) }
            }
        }
        if !queuesMessage, let threadID, let profileID {
            followsTranscriptTail = true
            pendingTranscriptReveal = (threadID, profileID, existingIDs, nil)
        }
    }

    private func clearAttachmentsAfterAcceptance(chatID: UUID) {
        guard let attachmentStore else { return }
        do {
            try attachmentStore.clear(chatID: chatID)
            if manager.selectedThreadID == chatID { configureAttachmentChips() }
        } catch {
            showRecovery("The message was sent, but its attached file context could not be cleared: \(error.localizedDescription)")
        }
    }

    @objc private func steerQueuedMessage(_ sender: QueuedMessageButton) {
        guard manager.canSteer, manager.queuedMessageInFlightID != sender.messageID else { return }
        window?.makeFirstResponder(composer)
        let threadID = manager.selectedThreadID
        let profileID = selectedProfileID()
        let existingIDs = Set(manager.messages.map(\.id))
        Task { [weak self] in
            guard let self else { return }
            guard self.selectedProfileID() == profileID, self.manager.selectedThreadID == threadID else {
                self.pendingTranscriptReveal = nil
                return
            }
            await self.manager.steerQueuedMessage(id: sender.messageID)
            guard let threadID, let profileID,
                  self.selectedProfileID() == profileID,
                  self.manager.selectedThreadID == threadID else { return }
            guard self.manager.messages.contains(where: { $0.id == sender.messageID }) else {
                if self.pendingTranscriptReveal?.expectedID == sender.messageID {
                    self.pendingTranscriptReveal = nil
                }
                return
            }
        }
        if let threadID, let profileID {
            followsTranscriptTail = true
            pendingTranscriptReveal = (threadID, profileID, existingIDs, sender.messageID)
        }
    }

    @objc private func removeQueuedMessage(_ sender: QueuedMessageButton) {
        guard manager.queuedMessageInFlightID != sender.messageID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.removeQueuedMessage(id: sender.messageID)
            } catch {
                self.showRecovery(error.localizedDescription)
            }
        }
    }

    @objc private func resumeQueue() {
        guard manager.queueIsPaused, isConnected else { return }
        Task { await manager.resumeQueue() }
    }

    @objc private func stopResponse() {
        Task { await manager.stop() }
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingDraft, notification.object as? NSTextView === composer else { return }
        manager.updateDraft(composer.string)
        updateComposerState()
    }

    private func loadAttachmentsForSelectedChat() {
        guard let chatID = manager.selectedThreadID, chatID != loadedAttachmentChatID else { return }
        guard let attachmentStore else { return }
        do { _ = try attachmentStore.load(chatID: chatID); loadedAttachmentChatID = chatID }
        catch { showRecovery(error.localizedDescription) }
    }

    private func configureAttachmentChips() {
        attachmentStack.arrangedSubviews.forEach { attachmentStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard let chatID = manager.selectedThreadID else { attachmentStack.isHidden = true; return }
        let attachments = attachmentStore?.attachments(chatID: chatID) ?? []
        for attachment in attachments {
            let remove = AttachmentRemoveButton(id: attachment.id, displayName: attachment.displayName)
            remove.target = self
            remove.action = #selector(removeAttachment(_:))
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attached file")
            remove.imagePosition = .imageOnly
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.controlSize = .small
            remove.setAccessibilityLabel("Remove attached file \(attachment.displayName)")
            let chip = NSStackView(views: [NSTextField(labelWithString: attachment.displayName), remove])
            chip.orientation = .horizontal
            chip.alignment = .centerY
            chip.spacing = 2
            attachmentStack.addArrangedSubview(chip)
        }
        attachmentStack.isHidden = attachments.isEmpty
    }

    @objc private func removeAttachment(_ sender: AttachmentRemoveButton) {
        guard let chatID = manager.selectedThreadID else { return }
        guard let attachmentStore else { presentAttachmentError("Attachments are unavailable for this project."); return }
        do { try attachmentStore.remove(chatID: chatID, attachmentID: sender.id); configureAttachmentChips() }
        catch { presentAttachmentError(error.localizedDescription) }
    }

    private func attachDroppedFiles(_ urls: [URL]) {
        for input in urls {
            let url = input.resolvingSymlinksInPath().standardizedFileURL
            guard let chatID = manager.selectedThreadID, let attachmentStore else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                presentAttachmentError("Only existing files can be attached.")
                continue
            }
            let rootPrefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
            do {
            if url.path.hasPrefix(rootPrefix) {
                let relative = String(url.path.dropFirst(rootPrefix.count))
                try attachmentStore.addProjectReference(chatID: chatID, relativePath: relative)
            } else {
                try attachmentStore.addExternalFile(chatID: chatID, url: url)
            }
            } catch { presentAttachmentError(error.localizedDescription) }
        }
        configureAttachmentChips()
    }

    private func presentAttachmentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File was not attached"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func refreshTranscript() {
        let messages = manager.messages
        let activities = manager.turnActivitySummaries
        let liveProgressText = manager.liveProgressText
        let liveProgressUserMessageID = manager.liveProgressUserMessageID
        guard messages != renderedMessages || activities != renderedActivities ||
                liveProgressText != renderedLiveProgressText ||
                liveProgressUserMessageID != renderedLiveProgressUserMessageID else { return }

        let previousMessages = renderedMessages
        let previousActivities = renderedActivities
        let sameCount = messages.count == previousMessages.count
        var changedRows = Set(zip(messages, previousMessages).enumerated().compactMap { index, pair in
            pair.0 == pair.1 ? nil : index
        })
        let previousByMessage = Dictionary(uniqueKeysWithValues: previousActivities.map { ($0.userMessageID, $0) })
        let currentByMessage = Dictionary(uniqueKeysWithValues: activities.map { ($0.userMessageID, $0) })
        for (index, message) in messages.enumerated() where message.role == .user {
            if previousByMessage[message.id] != currentByMessage[message.id] {
                changedRows.insert(index)
            }
        }
        if renderedLiveProgressText != liveProgressText ||
            renderedLiveProgressUserMessageID != liveProgressUserMessageID {
            if !previousMessages.isEmpty { changedRows.insert(previousMessages.count - 1) }
            if !messages.isEmpty { changedRows.insert(messages.count - 1) }
        }
        renderedMessages = messages
        renderedActivities = activities
        renderedLiveProgressText = liveProgressText
        renderedLiveProgressUserMessageID = liveProgressUserMessageID
        if sameCount {
            for row in changedRows { transcriptRowHeights.removeValue(forKey: row); rowMeasurementScheduled.remove(row) }
        } else {
            transcriptRowHeights.removeAll()
            rowMeasurementScheduled.removeAll()
        }
        if sameCount, !changedRows.isEmpty {
            let indexes = IndexSet(changedRows)
            transcriptTable.reloadData(
                forRowIndexes: indexes,
                columnIndexes: IndexSet(integer: 0)
            )
            transcriptTable.noteHeightOfRows(withIndexesChanged: indexes)
        } else {
            transcriptTable.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        renderedMessages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard renderedMessages.indices.contains(row) else { return nil }
        let message = renderedMessages[row]
        let cell = NSTableCellView()
        let isUser = message.role == .user
        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 5
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            rowStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: isUser ? 5 : 8),
            rowStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: isUser ? -7 : -8)
        ])

        let body: NSView
        if isUser {
            let label = NSTextField(wrappingLabelWithString: visibleMessageText(message.text))
            label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.alignment = .left
            label.font = .systemFont(ofSize: 14)
            body = label
        } else {
            let rendered = renderedAssistantMarkdown(for: message) ?? NSAttributedString(string: message.text)
            body = AssistantResponseTextView(
                rendered: attributedResponse(rendered, source: message.text),
                initialWidth: max(100, (tableColumn?.width ?? tableView.bounds.width) - 12),
                onOpenProjectFile: { [weak self] path in self?.openProjectFile(path) },
                onHeightChanged: { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    self.scheduleRowMeasurement(cell, row: row)
                }
            )
        }
        if isUser {
            let surface = UserMessageSurface()
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(body)
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
                body.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
                body.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8),
                body.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8)
            ])
            rowStack.addArrangedSubview(surface)
            surface.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        } else {
            rowStack.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: rowStack.widthAnchor, constant: -4).isActive = true
        }
        if row == renderedMessages.count - 1,
           let progress = renderedLiveProgressText,
           !progress.isEmpty,
           let progressOwner = renderedLiveProgressUserMessageID,
           renderedMessages.contains(where: { $0.id == progressOwner }) {
            let thinking = NSTextField(wrappingLabelWithString: progress)
            thinking.font = .systemFont(ofSize: 12)
            thinking.textColor = .secondaryLabelColor
            thinking.maximumNumberOfLines = 0
            thinking.isSelectable = true
            thinking.setAccessibilityLabel("Thinking")
            rowStack.addArrangedSubview(thinking)
            thinking.widthAnchor.constraint(equalTo: rowStack.widthAnchor, constant: -8).isActive = true
        }
        if message.role == .user,
           let summary = renderedActivities.first(where: { $0.userMessageID == message.id }),
           !summary.activities.isEmpty {
            let disclosure = TurnActivityDisclosureView(
                summary: summary,
                isExpanded: expandedActivityMessageIDs.contains(message.id)
            ) { [weak self, weak cell] in
                guard let self else { return }
                if self.expandedActivityMessageIDs.contains(message.id) {
                    self.expandedActivityMessageIDs.remove(message.id)
                } else {
                    self.expandedActivityMessageIDs.insert(message.id)
                }
                if let cell { self.scheduleRowMeasurement(cell, row: row) }
            }
            rowStack.addArrangedSubview(disclosure)
            disclosure.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        if message.role == .assistant {
            if let turnID = turnID(forAssistantMessageAt: row),
               let changes = renderedTurnFileChanges.first(where: { $0.turnID == turnID }) {
                let disclosure = TurnFilesDisclosureView(
                    changes: changes,
                    onOpen: { [weak self] hunk in self?.onOpenAgentChange?(hunk) },
                    onOpenPath: { [weak self] path in self?.openProjectFile(path) },
                    onRestore: { [weak self] in self?.confirmRestorePoint(turnID: turnID) },
                    isExpanded: expandedTurnFileIDs.contains(turnID),
                    onToggle: { [weak self, weak cell] expanded in
                        guard let self else { return }
                        if expanded { self.expandedTurnFileIDs.insert(turnID) } else { self.expandedTurnFileIDs.remove(turnID) }
                        if let cell { self.scheduleRowMeasurement(cell, row: row) }
                    }
                )
                rowStack.addArrangedSubview(disclosure)
                disclosure.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            }
            let copy = CopyMessageButton(messageText: message.text, target: self, action: #selector(copyAssistantMessage(_:)))
            copy.bezelStyle = .inline
            copy.isBordered = false
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy response")
            copy.imagePosition = .imageOnly
            copy.toolTip = "Copy response"
            copy.setAccessibilityLabel("Copy response")
            let footerSpacer = NSView()
            footerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
            let footer = NSStackView(views: [footerSpacer, copy])
            footer.orientation = .horizontal
            footer.alignment = .centerY
            rowStack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        scheduleRowMeasurement(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        transcriptRowHeights[row] ?? 52
    }

    private func scheduleRowMeasurement(_ cell: NSTableCellView, row: Int) {
        guard !visibleMeasurementScheduled,
              renderedMessages.indices.contains(row),
              rowMeasurementScheduled.insert(row).inserted else { return }
        let messageID = renderedMessages[row].id
        let measurementGeneration = transcriptLayoutGeneration
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self else { return }
            self.rowMeasurementScheduled.remove(row)
            guard let cell,
                  self.transcriptLayoutGeneration == measurementGeneration,
                  self.renderedMessages.indices.contains(row),
                  self.renderedMessages[row].id == messageID,
                  self.transcriptTable.view(atColumn: 0, row: row, makeIfNecessary: false) === cell else { return }
            cell.layoutSubtreeIfNeeded()
            let height = ceil(max(52, cell.fittingSize.height))
            guard abs((self.transcriptRowHeights[row] ?? 52) - height) > 0.5 else { return }
            self.applyRowHeightChanges([row: height])
        }
    }

    private func scheduleVisibleRowMeasurements() {
        guard !visibleMeasurementScheduled else { return }
        visibleMeasurementScheduled = true
        let measurementGeneration = transcriptLayoutGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.transcriptLayoutGeneration == measurementGeneration else {
                self.visibleMeasurementScheduled = false
                self.scheduleVisibleRowMeasurements()
                return
            }
            defer { self.visibleMeasurementScheduled = false }
            guard self.transcriptTable.numberOfRows > 0 else { return }
            let visible = self.transcriptTable.rows(in: self.transcriptTable.visibleRect)
            guard visible.location != NSNotFound else { return }
            var changes: [Int: CGFloat] = [:]
            for row in visible.location..<(visible.location + visible.length) {
                guard let cell = self.transcriptTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { continue }
                guard self.renderedMessages.indices.contains(row) else { continue }
                cell.layoutSubtreeIfNeeded()
                let height = ceil(max(52, cell.fittingSize.height))
                if abs((self.transcriptRowHeights[row] ?? 52) - height) > 0.5 {
                    changes[row] = height
                }
            }
            let anchor = self.pendingTranscriptResizeAnchor
            self.pendingTranscriptResizeAnchor = nil
            self.applyRowHeightChanges(changes, anchor: anchor)
        }
    }

    private func applyRowHeightChanges(
        _ changes: [Int: CGFloat],
        anchor: TranscriptViewportAnchor? = nil
    ) {
        guard !changes.isEmpty else { return }
        let anchor = anchor ?? transcriptViewportAnchor()
        for (row, height) in changes {
            transcriptRowHeights[row] = height
        }
        let rows = IndexSet(changes.keys)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            transcriptTable.noteHeightOfRows(withIndexesChanged: rows)
            transcriptTable.layoutSubtreeIfNeeded()
            restoreTranscriptViewport(anchor)
        }
    }

    private func transcriptViewportAnchor() -> TranscriptViewportAnchor {
        guard !followsTranscriptTail else { return .tail }
        let visible = transcriptTable.visibleRect
        let visibleRows = transcriptTable.rows(in: visible)
        guard visibleRows.location != NSNotFound,
              renderedMessages.indices.contains(visibleRows.location)
        else { return .tail }
        let row = visibleRows.location
        let rowRect = transcriptTable.rect(ofRow: row)
        return .message(id: renderedMessages[row].id, offset: visible.minY - rowRect.minY)
    }

    private func restoreTranscriptViewport(_ anchor: TranscriptViewportAnchor) {
        let clipView = transcriptScrollView.contentView
        let maximumOriginY = max(0, transcriptTable.frame.height - clipView.bounds.height)
        let originY: CGFloat
        switch anchor {
        case .tail:
            originY = maximumOriginY
        case .message(let id, let offset):
            guard let row = renderedMessages.firstIndex(where: { $0.id == id }) else { return }
            originY = min(max(0, transcriptTable.rect(ofRow: row).minY + offset), maximumOriginY)
        }
        isProgrammaticTranscriptScroll = true
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: originY))
        transcriptScrollView.reflectScrolledClipView(clipView)
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticTranscriptScroll = false
        }
    }

    private func scrollTranscriptToRow(_ row: Int) {
        guard transcriptTable.numberOfRows > row else { return }
        isProgrammaticTranscriptScroll = true
        transcriptTable.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticTranscriptScroll = false
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    @objc private func copyAssistantMessage(_ sender: NSButton) {
        guard let copy = sender as? CopyMessageButton else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copy.messageText, forType: .string)
    }

    private func projectPathsMentioned(in text: String) -> [String] {
        var seen = Set<String>()
        func valid(_ candidate: String) -> String? {
            let relative = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relative.hasPrefix("http"), !relative.contains(".."), !relative.contains("://"),
                  FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(relative).path),
                  seen.insert(relative).inserted else { return nil }
            return relative
        }
        let patterns = [
            "`([^`\\n]+)`",                         // inline code paths, including spaces
            "\\[[^]]*\\]\\(([^ )]+)\\)",             // Markdown link destinations
            "(?<![A-Za-z0-9_./-])((?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_-]+\\.[A-Za-z0-9]{1,12})",
            "(?<![A-Za-z0-9_./-])([A-Za-z0-9_-]+\\.[A-Za-z0-9]{1,12})" // bare root filenames
        ]
        return patterns.flatMap { pattern -> [String] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return expression.matches(in: text, range: range).compactMap { match in
                guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
                return valid(String(text[swiftRange]))
            }
        }
    }

    private func visibleMessageText(_ text: String) -> String {
        guard let marker = text.range(of: "\n\n<fs_code_attachments>") else { return text }
        return String(text[..<marker.lowerBound])
    }

    /// Older locally saved messages predate `ConversationMessage.turnID`. Their
    /// persisted activity summary still binds the preceding user request to its turn.
    private func turnID(forAssistantMessageAt row: Int) -> String? {
        let message = renderedMessages[row]
        guard message.role == .assistant else { return nil }
        if let direct = message.turnID {
            let hasLaterChunk = renderedMessages.indices.contains(row + 1)
                && renderedMessages[row + 1].role == .assistant
                && renderedMessages[row + 1].turnID == direct
            return hasLaterChunk ? nil : direct
        }
        // Keep a legacy turn disclosure on its final assistant chunk only.
        if renderedMessages.indices.contains(row + 1), renderedMessages[row + 1].role == .assistant { return nil }
        guard let userIndex = renderedMessages[..<row].lastIndex(where: { $0.role == .user }) else { return nil }
        return renderedActivities.first(where: { $0.userMessageID == renderedMessages[userIndex].id })?.remoteTurnID
    }

    private func openProjectFile(_ relativePath: String) {
        onOpenProjectFile?(relativePath)
    }

    private func attributedResponse(_ rendered: NSAttributedString, source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: rendered)
        let all = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.link, in: all) { value, range, _ in
            let raw = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            guard !raw.isEmpty, !raw.hasPrefix("http://"), !raw.hasPrefix("https://"),
                  let path = raw.removingPercentEncoding,
                  let projectPath = projectPathsMentioned(in: "`\(path)`").first,
                  let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let controlled = URL(string: "fscode-file://open/\(encoded)") else { return }
            result.addAttribute(.link, value: controlled, range: range)
        }
        for path in projectPathsMentioned(in: source) {
            let range = (result.string as NSString).range(of: path)
            guard range.location != NSNotFound,
                  result.attribute(.link, at: range.location, effectiveRange: nil) == nil,
                  let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "fscode-file://open/\(encoded)") else { continue }
            result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return result
    }

    private func confirmRestorePoint(turnID: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore files to before this turn?"
        alert.informativeText = "Later changes from this chat will also be undone. Conversation history is kept."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        let restore: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do { try await self.manager.restorePoint(turnID: turnID) }
                catch { self.showRecovery(error.localizedDescription) }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: restore) }
        else { restore(alert.runModal()) }
    }

    private func renderedAssistantMarkdown(for message: ConversationMessage) -> NSAttributedString? {
        let fenceCount = message.text.components(separatedBy: "```").count - 1
        guard message.role == .assistant,
              message.text.utf8.count <= 1_048_576,
              fenceCount.isMultiple(of: 2) else {
            return nil
        }
        if let cached = renderedAssistantMessages[message.id],
           cached.source == message.text,
           cached.phase == message.phase {
            return cached.rendered
        }
        guard let source = MarkdownPreviewView.renderedMarkdown(message.text, presentation: .assistant) else { return nil }
        let rendered = NSMutableAttributedString(attributedString: source)
        let range = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.font, in: range) { value, fontRange, _ in
            guard let font = value as? NSFont,
                  abs(font.pointSize - NSFont.systemFontSize) < 0.1 else { return }
            rendered.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: 14) ?? font, range: fontRange)
        }
        if message.phase == .commentary {
            rendered.enumerateAttribute(.foregroundColor, in: range) { value, colorRange, _ in
                guard (value as? NSColor) != NSColor.linkColor else { return }
                rendered.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: colorRange)
            }
        }
        renderedAssistantMessages[message.id] = (source: message.text, phase: message.phase, rendered: rendered)
        return rendered
    }

    private func showRecovery(_ message: String) {
        localRecoveryMessage = message
        refreshInterface()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColors()
    }

    private func updateSurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            transcriptTable.backgroundColor = .clear
            transcriptScrollView.backgroundColor = .clear
            composerContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            composerContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

private struct QueueRenderState: Equatable {
    let messages: [ConversationQueuedMessage]
    let isPaused: Bool
    let error: String?
    let canSteer: Bool
    let inFlightID: UUID?
    let isConnected: Bool
}

@MainActor
private final class TurnActivityDisclosureView: NSView {
    private let onToggle: () -> Void
    private let button = NSButton(frame: .zero)
    private let details = NSStackView()
    private var isExpanded: Bool

    init(summary: ConversationTurnActivitySummary, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        self.isExpanded = isExpanded
        super.init(frame: .zero)

        button.title = Self.summaryText(summary.activities)
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse activity" : "Expand activity"
        )
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggle)
        button.alignment = .left
        button.setAccessibilityLabel("Turn activity: \(button.title)")

        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        for activity in summary.activities {
            let detail = Self.detailView(for: activity)
            details.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        details.isHidden = !isExpanded

        let stack = NSStackView(views: [button, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        details.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -14).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func toggle() {
        isExpanded.toggle()
        details.isHidden = !isExpanded
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse activity" : "Expand activity"
        )
        onToggle()
    }

    private static func summaryText(_ activities: [ConversationTurnActivity]) -> String {
        let phases = activities.map(\.phase).reduce(into: [ConversationActivityPhase]()) { result, phase in
            if !result.contains(phase) { result.append(phase) }
        }.sorted { $0.rawValue < $1.rawValue }
        let phaseText = phases.count == 1 ? phaseName(phases[0]) : "Work"
        let status = activities.contains(where: { $0.completedAt == nil })
            ? "Running"
            : (activities.last(where: { $0.status?.isEmpty == false })?.status ?? "Completed")
        let milliseconds = activities.compactMap(\.durationMs).reduce(0.0) { $0 + Double($1) }
        let duration = milliseconds > 0 ? " · \(durationText(Int(min(milliseconds, Double(Int.max)))))" : ""
        let count = activities.count == 1 ? "1 step" : "\(activities.count) steps"
        return "\(phaseText) · \(count) · \(status.capitalized)\(duration)"
    }

    private static func detailView(for activity: ConversationTurnActivity) -> NSView {
        let title = NSTextField(wrappingLabelWithString: activity.operation ?? phaseName(activity.phase))
        title.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        title.maximumNumberOfLines = 0
        title.isSelectable = true
        title.attributedStringValue = MarkdownPreviewView.renderedToolText(title.stringValue)

        var metadata: [String] = [phaseName(activity.phase)]
        if let status = activity.status, !status.isEmpty { metadata.append(status.capitalized) }
        if let duration = activity.durationMs { metadata.append(durationText(duration)) }
        let subtitle = NSTextField(labelWithString: metadata.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .tertiaryLabelColor

        let content = NSStackView(views: [title, subtitle])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        title.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let output = activity.output, !output.isEmpty {
            let bounded = String(output.prefix(12_000)) + (output.count > 12_000 ? "\n… output truncated" : "")
            let text = NSTextView(frame: .zero)
            text.textStorage?.setAttributedString(MarkdownPreviewView.renderedToolText(bounded))
            text.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            text.textColor = .labelColor
            text.backgroundColor = .controlBackgroundColor
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 7, height: 6)
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .controlBackgroundColor
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 5
            scroll.heightAnchor.constraint(equalToConstant: min(132, max(48, CGFloat(bounded.split(separator: "\n").count * 14 + 16)))).isActive = true
            content.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return content
    }

    private static func phaseName(_ phase: ConversationActivityPhase) -> String {
        switch phase {
        case .reasoning: "Reasoning"
        case .command: "Command"
        case .dynamicTool: "Tool"
        case .mcp: "MCP"
        }
    }

    private static func durationText(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
}

@MainActor
private final class UserMessageSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0.5
        }
    }
}

@MainActor
private final class CopyMessageButton: NSButton {
    let messageText: String

    init(messageText: String, target: AnyObject?, action: Selector?) {
        self.messageText = messageText
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
private final class AttachmentRemoveButton: NSButton {
    let id: UUID
    init(id: UUID, displayName: String) {
        self.id = id
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
private final class AssistantResponseTextView: NSTextView, NSTextViewDelegate {
    private let onOpenProjectFile: (String) -> Void
    private let onHeightChanged: () -> Void
    private let responseStorage = NSTextStorage()
    private let responseLayoutManager = NSLayoutManager()
    private let responseContainer: NSTextContainer
    private var heightInvalidationScheduled = false
    private var preferredHeight: CGFloat = 20

    init(rendered: NSAttributedString, initialWidth: CGFloat, onOpenProjectFile: @escaping (String) -> Void, onHeightChanged: @escaping () -> Void) {
        self.onOpenProjectFile = onOpenProjectFile
        self.onHeightChanged = onHeightChanged
        responseContainer = NSTextContainer(size: NSSize(width: initialWidth, height: CGFloat.greatestFiniteMagnitude))
        responseStorage.addLayoutManager(responseLayoutManager)
        responseLayoutManager.addTextContainer(responseContainer)
        super.init(frame: .zero, textContainer: responseContainer)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        font = .systemFont(ofSize: 14)
        textContainerInset = NSSize(width: 0, height: 0)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        responseContainer.containerSize = NSSize(width: initialWidth, height: CGFloat.greatestFiniteMagnitude)
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        responseStorage.setAttributedString(rendered)
        preferredHeight = measuredHeight(for: initialWidth)
        delegate = self
        setAccessibilityLabel("Assistant response")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, !heightInvalidationScheduled else { return }
        heightInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightInvalidationScheduled = false
            guard self.bounds.width > 0 else { return }
            let nextHeight = self.measuredHeight(for: self.bounds.width)
            guard abs(nextHeight - self.preferredHeight) > 0.5 else { return }
            self.preferredHeight = nextHeight
            self.invalidateIntrinsicContentSize()
            self.onHeightChanged()
        }
    }
    private func measuredHeight(for width: CGFloat) -> CGFloat {
        responseContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        responseLayoutManager.ensureLayout(for: responseContainer)
        return max(20, ceil(responseLayoutManager.usedRect(for: responseContainer).height + textContainerInset.height * 2))
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return true }
        if url.scheme == "fscode-file", let path = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            onOpenProjectFile(path)
            return true
        }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        return true
    }
}

@MainActor
private final class TurnFilesDisclosureView: NSView {
    private let details = NSStackView()
    private let toggle = NSButton(frame: .zero)
    private var expanded = false
    private var actionTargets: [BlockTarget] = []

    private let onToggle: (Bool) -> Void
    init(changes: ConversationTurnFileChanges, onOpen: @escaping (AgentFileChangeHunk) -> Void, onOpenPath: @escaping (String) -> Void, onRestore: @escaping () -> Void, isExpanded: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        let unique = Dictionary(grouping: changes.records, by: \.relativePath)
        toggle.title = "Modified Files (\(unique.count))"
        toggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show modified files")
        toggle.imagePosition = .imageLeading
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleDetails)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3
        for (_, records) in unique.sorted(by: { $0.key < $1.key }) {
            guard let hunk = records.flatMap(\.changeHunks).first(where: { !$0.isReverted }) else {
                let path = records[0].relativePath
                let button = NSButton(title: path, target: nil, action: nil)
                let target = BlockTarget { onOpenPath(path) }
                actionTargets.append(target)
                button.target = target
                button.action = #selector(BlockTarget.invoke)
                button.bezelStyle = .inline
                button.controlSize = .small
                button.toolTip = "Open file if it still exists"
                details.addArrangedSubview(button)
                continue
            }
            let button = AgentChangeOpenButton(hunk: hunk)
            button.title = hunk.relativePath
            button.bezelStyle = .inline
            button.controlSize = .small
            let target = BlockTarget { onOpen(hunk) }
            actionTargets.append(target)
            button.target = target
            button.action = #selector(BlockTarget.invoke)
            details.addArrangedSubview(button)
        }
        let restore = NSButton(title: "Restore Point", target: nil, action: nil)
        restore.bezelStyle = .inline
        restore.controlSize = .small
        let restoreTarget = BlockTarget { onRestore() }
        actionTargets.append(restoreTarget)
        restore.target = restoreTarget
        restore.action = #selector(BlockTarget.invoke)
        details.addArrangedSubview(restore)
        expanded = isExpanded
        details.isHidden = !isExpanded
        toggle.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: isExpanded ? "Hide modified files" : "Show modified files")
        let stack = NSStackView(views: [toggle, details])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func toggleDetails() { expanded.toggle(); details.isHidden = !expanded; toggle.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Hide modified files" : "Show modified files"); onToggle(expanded) }
}

@MainActor
private final class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}

@MainActor
private final class QueuedMessageButton: NSButton {
    let messageID: UUID

    init(messageID: UUID) {
        self.messageID = messageID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
private final class AgentChangeOpenButton: NSButton {
    let hunk: AgentFileChangeHunk

    init(hunk: AgentFileChangeHunk) {
        self.hunk = hunk
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
private final class ComposerTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let rect = NSRect(
            x: textContainerInset.width + padding,
            y: textContainerInset.height,
            width: max(0, bounds.width - textContainerInset.width * 2 - padding * 2),
            height: max(0, bounds.height - textContainerInset.height * 2)
        )
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if isReturn, modifiers == [.command], !hasMarkedText() {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if isReturn, modifiers.isEmpty, !hasMarkedText() {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap { $0 as? URL } ?? []
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }
}

@MainActor
private final class CompactMenuButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 12)
        imagePosition = .imageLeading
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
