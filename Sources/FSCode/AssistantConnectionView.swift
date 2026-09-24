import AppKit
import AgentConnectionCore

@MainActor
final class AssistantConnectionView: NSView {
    private let manager: AgentConnectionManager
    private let chatView: AssistantChatView
    private var observerID: UUID?
    private var clientID: UUID?
    private var activeSheet: NSWindowController?
    private var localRecoveryMessage: String?
    private static var openedLoginURL: URL?
    private var requestedLoginFromThisView = false
    private var loginWasInitiatedHere = false
    private var didRestoreSelectedSession = false

    private let connectionPopup: NSPopUpButton
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let copyCodeButton = NSButton(title: "Copy Code", target: nil, action: nil)
    private let addLLMButton = NSButton(title: "Connect Model…", target: nil, action: nil)
    private let manageButton: NSButton
    private let setupManageButton = NSButton(title: "", target: nil, action: nil)

    init(manager: AgentConnectionManager, projectURL: URL) {
        self.manager = manager
        let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        self.connectionPopup = connectionPopup
        let manageButton = NSButton(title: "", target: nil, action: nil)
        self.manageButton = manageButton
        chatView = AssistantChatView(
            manager: AgentConversationManager(projectURL: projectURL, connectionManager: manager),
            connectionManager: manager,
            projectURL: projectURL,
            selectedProfileID: { manager.selectedProfileID },
            onAddConnection: {},
            onManageConnections: { _ in }
        )
        super.init(frame: .zero)
        chatView.onAddConnection = { [weak self] in
            self?.addConnection()
        }
        chatView.onManageConnections = { [weak self] anchor in
            guard let self else { return }
            self.showManageMenu(anchor)
        }
        wantsLayer = true
        updateSurfaceColor()
        setAccessibilityLabel("Assistant connection")
        buildInterface()
        updateInterface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        startObserving()
        if clientID == nil { clientID = manager.acquireClient() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.load()
                if !self.didRestoreSelectedSession,
                   self.manager.selectedProfileID != nil {
                    self.didRestoreSelectedSession = true
                    await self.manager.refreshSelected()
                }
            } catch {
                self.showLocalRecovery("Unable to load connections. Try again.")
            }
            self.updateInterface()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func executePlan(planID: String) async throws {
        try await chatView.executePlan(planID: planID)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColor()
    }

    private func updateSurfaceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        shutdown()
    }

    func shutdown() {
        chatView.detach()
        if let observerID {
            manager.removeObserver(observerID)
            self.observerID = nil
        }
        if let clientID {
            self.clientID = nil
            Task { await manager.releaseClient(clientID) }
        }
    }

    func shutdownConversation() async {
        do {
            try await chatView.shutdownConversation()
        } catch {
            showConversationSaveError(error)
        }
    }

    func flushConversation() async -> Bool {
        do {
            try await chatView.flushConversation()
            return true
        } catch {
            showConversationSaveError(error)
            return false
        }
    }

    func configureFileMutationHandlers(
        authorize: @escaping @MainActor @Sendable (String, ConversationFileMutationOperation) async -> Bool,
        didComplete: @escaping @MainActor @Sendable (ConversationFileMutationResult) -> Void
    ) {
        chatView.configureFileMutationHandlers(authorize: authorize, didComplete: didComplete)
    }

    func configureAgentModifiedPathsObserver(
        _ observer: @escaping @MainActor @Sendable (Set<String>) -> Void
    ) {
        chatView.configureAgentModifiedPathsObserver(observer)
    }

    func configureAppliedChangesObserver(
        _ observer: @escaping @MainActor @Sendable ([AgentFileChangeRecord]) -> Void
    ) {
        chatView.configureAppliedChangesObserver(observer)
    }

    func configureAgentChangeOpenHandler(
        _ handler: @escaping @MainActor @Sendable (AgentFileChangeHunk) -> Void
    ) {
        chatView.configureAgentChangeOpenHandler(handler)
    }

    func configureProjectFileOpenHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        chatView.configureProjectFileOpenHandler(handler)
    }

    func revertAgentChange(_ hunk: AgentFileChangeHunk) {
        chatView.revertAgentChange(hunk)
    }

    private func buildInterface() {
        connectionPopup.target = self
        connectionPopup.action = #selector(connectionChanged)
        connectionPopup.setAccessibilityLabel("Connection")

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("Connection status")
        recoveryLabel.font = .systemFont(ofSize: 11)
        recoveryLabel.textColor = .secondaryLabelColor
        recoveryLabel.maximumNumberOfLines = 2

        for (button, action, label) in [
            (connectButton, #selector(connect), "Connect"),
            (cancelButton, #selector(cancelLogin), "Cancel sign in"),
            (copyCodeButton, #selector(copyDeviceCode), "Copy device code"),
            (addLLMButton, #selector(addConnection), "Connect Model"),
            (manageButton, #selector(showManageMenu(_:)), "Connection options"),
            (setupManageButton, #selector(showManageMenu(_:)), "Connection options")
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        manageButton.title = ""
        manageButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Connection options")
        manageButton.imagePosition = .imageOnly
        manageButton.toolTip = "Connection options"
        setupManageButton.title = ""
        setupManageButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Connection options")
        setupManageButton.imagePosition = .imageOnly
        setupManageButton.toolTip = "Connection options"
        let primaryActions = NSStackView(views: [addLLMButton, connectButton, cancelButton, copyCodeButton, setupManageButton])
        primaryActions.orientation = .horizontal
        primaryActions.alignment = .centerY
        primaryActions.spacing = 6

        chatView.setContentHuggingPriority(.defaultLow, for: .vertical)
        chatView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let content = NSStackView(views: [
            statusLabel, recoveryLabel, primaryActions, chatView
        ])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        for control in [statusLabel, recoveryLabel, primaryActions] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        }
        chatView.translatesAutoresizingMaskIntoConstraints = false
        chatView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        connectionPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            chatView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func startObserving() {
        guard observerID == nil else { return }
        observerID = manager.addObserver { [weak self] in self?.updateInterface() }
    }

    var hasActiveConnectionObservation: Bool { observerID != nil && clientID != nil }

    private var selectedProfile: ConnectionProfile? {
        guard let selectedID = manager.selectedProfileID else { return nil }
        return manager.profiles.first { $0.id == selectedID }
    }

    private func updateInterface() {
        if case .awaitingBrowserLogin = manager.state {
            if requestedLoginFromThisView {
                loginWasInitiatedHere = true
            }
        } else {
            Self.openedLoginURL = nil
        }
        let profiles = manager.profiles
        let selectedID = manager.selectedProfileID
        connectionPopup.removeAllItems()
        if profiles.isEmpty {
            connectionPopup.addItem(withTitle: "No connection selected")
            connectionPopup.lastItem?.representedObject = nil
            connectionPopup.isEnabled = false
        } else {
            connectionPopup.isEnabled = true
            connectionPopup.addItem(withTitle: "Select a connection")
            connectionPopup.lastItem?.representedObject = nil
            for profile in profiles {
                connectionPopup.addItem(withTitle: "\(profile.name) — \(profile.kind.displayName)")
                connectionPopup.lastItem?.representedObject = profile.id
            }
            if let selectedID,
               let index = profiles.firstIndex(where: { $0.id == selectedID }) {
                connectionPopup.selectItem(at: index + 1)
            } else {
                connectionPopup.selectItem(at: 0)
            }
        }

        statusLabel.stringValue = manager.state.statusText
        statusLabel.textColor = statusColor(for: manager.state)
        let isLoggingIn: Bool
        switch manager.state {
        case .connecting, .awaitingBrowserLogin, .loadingModels: isLoggingIn = true
        default: isLoggingIn = false
        }
        let isConnected: Bool
        if case .connected = manager.state { isConnected = true } else { isConnected = false }
        connectButton.title = "Connect"
        connectButton.isEnabled = selectedProfile != nil && !isLoggingIn
        cancelButton.isEnabled = isLoggingIn
        cancelButton.isHidden = !isLoggingIn
        copyCodeButton.isHidden = manager.pendingDeviceCode == nil
        copyCodeButton.isEnabled = manager.pendingDeviceCode != nil
        if let code = manager.pendingDeviceCode {
            statusLabel.stringValue = "Open auth.openai.com/codex/device and enter code: \(code)"
            statusLabel.isSelectable = true
        }
        addLLMButton.isHidden = isConnected || isLoggingIn || selectedProfile != nil
        connectButton.isHidden = isConnected || selectedProfile == nil
        manageButton.isEnabled = isConnected && !isLoggingIn
        setupManageButton.isHidden = isConnected || isLoggingIn
        setupManageButton.isEnabled = !isLoggingIn
        switch manager.state {
        case .unloaded, .disconnected, .connected, .failed:
            statusLabel.isHidden = true
        case .connecting, .awaitingBrowserLogin, .loadingModels:
            statusLabel.isHidden = false
        }
        chatView.isHidden = !isConnected

        let loginFinished: Bool
        if case .failed = manager.state { loginFinished = true } else { loginFinished = isConnected }
        if loginFinished, loginWasInitiatedHere {
            loginWasInitiatedHere = false
            requestedLoginFromThisView = false
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if let localRecoveryMessage {
            recoveryLabel.stringValue = localRecoveryMessage
        } else if case .failed = manager.state {
            recoveryLabel.stringValue = manager.state.statusText
        } else {
            recoveryLabel.stringValue = ""
        }
        recoveryLabel.isHidden = recoveryLabel.stringValue.isEmpty
        openPendingLoginIfNeeded()
    }

    private func statusColor(for state: AgentConnectionState) -> NSColor {
        switch state {
        case .connected: return .systemGreen
        case .connecting, .awaitingBrowserLogin, .loadingModels: return .systemOrange
        case .failed: return .systemRed
        case .unloaded, .disconnected: return .secondaryLabelColor
        }
    }

    @objc private func connectionChanged() {
        let id = connectionPopup.selectedItem?.representedObject as? UUID
        Task { await manager.selectProfile(id: id) }
    }


    @objc private func connect() {
        guard selectedProfile != nil else { return }
        localRecoveryMessage = nil
        requestedLoginFromThisView = selectedProfile?.kind == .chatGPT
        Task { await manager.connectSelected() }
    }

    @objc private func cancelLogin() {
        localRecoveryMessage = nil
        requestedLoginFromThisView = false
        loginWasInitiatedHere = false
        Task { await manager.cancelLogin() }
    }

    @objc private func copyDeviceCode() {
        guard let code = manager.pendingDeviceCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    @objc private func refresh() {
        localRecoveryMessage = nil
        Task { await manager.refreshSelected() }
    }

    @objc private func signOut() {
        localRecoveryMessage = nil
        Task { await manager.logoutSelected() }
    }

    @objc private func showManageMenu(_ sender: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Connect Model…", action: #selector(addConnection), keyEquivalent: "").target = self
        if !manager.profiles.isEmpty {
            let accounts = NSMenuItem(title: "Switch Connection", action: nil, keyEquivalent: "")
            let accountsMenu = NSMenu()
            for profile in manager.profiles {
                let item = accountsMenu.addItem(
                    withTitle: "\(profile.name) — \(profile.kind.displayName)",
                    action: #selector(selectConnectionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id
                item.state = profile.id == manager.selectedProfileID ? .on : .off
            }
            accounts.submenu = accountsMenu
            menu.addItem(accounts)
        }
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = selectedProfile != nil
        menu.addItem(.separator())
        let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameConnection), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = selectedProfile != nil
        let remove = menu.addItem(withTitle: "Remove", action: #selector(removeConnection), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = selectedProfile != nil
        if selectedProfile?.kind == .openAIAPI {
            let replace = menu.addItem(withTitle: "Replace API Key…", action: #selector(replaceAPIKey), keyEquivalent: "")
            replace.target = self
        }
        let signOut = menu.addItem(withTitle: "Sign Out", action: #selector(signOut), keyEquivalent: "")
        signOut.target = self
        signOut.isEnabled = selectedProfile != nil
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func selectConnectionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task { await manager.selectProfile(id: id) }
    }

    @objc private func addConnection() {
        guard let window else { return }
        let sheet = NewConnectionSheetController()
        activeSheet = sheet
        sheet.present(over: window) { [weak self] request in
            guard let self else { return }
            self.activeSheet = nil
            guard let request else { return }
            Task {
                do {
                    let profile = try await self.manager.createProfile(name: request.name, kind: request.kind, apiKey: request.apiKey)
                    if request.kind == .chatGPT {
                        await self.manager.selectProfile(id: profile.id)
                        self.requestedLoginFromThisView = true
                        await self.manager.connectSelected()
                    }
                } catch {
                    self.showLocalRecovery("Unable to connect the model. Try again.")
                }
            }
        }
    }

    @objc private func renameConnection() {
        guard let profile = selectedProfile, let window else { return }
        let sheet = RenameConnectionSheetController(profile: profile)
        activeSheet = sheet
        sheet.present(over: window) { [weak self] name in
            guard let self else { return }
            self.activeSheet = nil
            guard let name else { return }
            Task {
                do {
                    try await self.manager.renameProfile(id: profile.id, name: name)
                } catch {
                    self.showLocalRecovery("Unable to rename the connection. Try again.")
                }
            }
        }
    }

    @objc private func removeConnection() {
        guard let profile = selectedProfile, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.name)?"
        alert.informativeText = "This removes the saved connection from FS Code."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do {
                    try await self.manager.removeProfile(id: profile.id)
                } catch {
                    self.showLocalRecovery("Unable to remove the connection. Try again.")
                }
            }
        }
    }

    @objc private func replaceAPIKey() {
        guard let profile = selectedProfile, profile.kind == .openAIAPI, let window else { return }
        let sheet = APIKeySheetController(profileName: profile.name)
        activeSheet = sheet
        sheet.present(over: window) { [weak self] apiKey in
            guard let self else { return }
            self.activeSheet = nil
            guard let apiKey else { return }
            self.localRecoveryMessage = nil
            Task {
                await self.manager.selectProfile(id: profile.id)
                guard self.manager.selectedProfileID == profile.id else {
                    self.showLocalRecovery("That connection is no longer available.")
                    return
                }
                await self.manager.connectSelected(apiKey: apiKey)
            }
        }
    }

    private func openPendingLoginIfNeeded() {
        guard case .awaitingBrowserLogin = manager.state,
              let url = manager.pendingLoginURL,
              url != Self.openedLoginURL,
              isOfficialLoginURL(url) else { return }
        Self.openedLoginURL = url
        NSWorkspace.shared.open(url)
    }

    private func isOfficialLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    private var runtimeIsMissing: Bool {
        guard case .failed(let message) = manager.state else { return false }
        let normalized = message.localizedLowercase
        return normalized.contains("codex") && (normalized.contains("not found") || normalized.contains("missing") || normalized.contains("executable"))
    }

    private func showLocalRecovery(_ message: String) {
        localRecoveryMessage = message
        updateInterface()
    }

    private func showConversationSaveError(_ error: Error) {
        showLocalRecovery(
            "Conversation history wasn’t saved. Keep this workspace open and reload before closing. \(error.localizedDescription)"
        )
    }
}

private extension ConnectionKind {
    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .openAIAPI: return "OpenAI API"
        }
    }
}

private final class ConnectionSetupSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class NewConnectionSheetController: NSWindowController {
    private let nameField = NSTextField(string: "")
    private let integrationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let apiKeyLabel = NSTextField(labelWithString: "API key")
    private let apiKeyField = NSSecureTextField(string: "")
    private let methodNote = NSTextField(wrappingLabelWithString: "")
    private var completion: ((NewConnectionRequest?) -> Void)?

    init() {
        let window = ConnectionSetupSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Connect Model"
        window.isReleasedWhenClosed = false
        window.onCancel = { [weak self] in self?.cancel() }
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(over host: NSWindow, completion: @escaping (NewConnectionRequest?) -> Void) {
        self.completion = completion
        host.beginSheet(window!)
    }

    private func buildInterface(in window: NSWindow) {
        let root = NSView()
        window.contentView = root
        let nameLabel = NSTextField(labelWithString: "Connection name")
        nameField.placeholderString = "My connection"
        nameField.setAccessibilityLabel("Connection name")
        let integrationLabel = NSTextField(labelWithString: "Connection type")
        integrationPopup.addItems(withTitles: ["ChatGPT", "OpenAI API"])
        integrationPopup.target = self
        integrationPopup.action = #selector(integrationChanged)
        integrationPopup.setAccessibilityLabel("Connection type")
        apiKeyField.placeholderString = "Required for OpenAI API"
        apiKeyField.setAccessibilityLabel("OpenAI API key")
        methodNote.font = .systemFont(ofSize: 11)
        methodNote.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let add = NSButton(title: "Connect", target: self, action: #selector(add))
        add.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        let content = NSStackView(views: [nameLabel, nameField, integrationLabel, integrationPopup, apiKeyLabel, apiKeyField, methodNote, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        for view in [nameField, integrationPopup, apiKeyField, methodNote, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        apiKeyLabel.isHidden = true
        apiKeyField.isHidden = true
        updateIntegrationNote()
        window.initialFirstResponder = nameField
    }

    @objc private func integrationChanged() {
        let needsAPIKey = integrationPopup.indexOfSelectedItem == 1
        apiKeyLabel.isHidden = !needsAPIKey
        apiKeyField.isHidden = !needsAPIKey
        if !needsAPIKey { apiKeyField.stringValue = "" }
        updateIntegrationNote()
    }

    private func updateIntegrationNote() {
        if integrationPopup.indexOfSelectedItem == 1 {
            methodNote.stringValue = "Your API key is stored securely in macOS Keychain. API usage is billed separately from ChatGPT."
        } else {
            methodNote.stringValue = "Sign in with your ChatGPT account in your browser. Access follows your plan."
        }
    }

    @objc private func add() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(nameField)
            return
        }
        let kind: ConnectionKind = integrationPopup.indexOfSelectedItem == 1 ? .openAIAPI : .chatGPT
        let apiKey = kind == .openAIAPI ? apiKeyField.stringValue : nil
        if kind == .openAIAPI, apiKey?.isEmpty != false {
            NSSound.beep()
            window?.makeFirstResponder(apiKeyField)
            return
        }
        apiKeyField.stringValue = ""
        dismiss(NewConnectionRequest(name: name, kind: kind, apiKey: apiKey))
    }

    @objc private func cancel() {
        apiKeyField.stringValue = ""
        dismiss(nil)
    }

    private func dismiss(_ request: NewConnectionRequest?) {
        guard let sheet = window, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
        sheet.orderOut(nil)
        completion?(request)
        completion = nil
    }
}

private struct NewConnectionRequest {
    let name: String
    let kind: ConnectionKind
    let apiKey: String?
}

@MainActor
private final class APIKeySheetController: NSWindowController {
    private let keyField = NSSecureTextField(string: "")
    private var completion: ((String?) -> Void)?

    init(profileName: String) {
        let window = ConnectionSetupSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Replace API Key"
        window.onCancel = { [weak self] in self?.cancel() }
        let root = NSView()
        window.contentView = root
        let text = NSTextField(wrappingLabelWithString: "Enter a replacement API key for \(profileName). It is stored securely in macOS Keychain.")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        keyField.placeholderString = "OpenAI API key"
        keyField.setAccessibilityLabel("Replacement OpenAI API key")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let replace = NSButton(title: "Replace", target: self, action: #selector(replace))
        replace.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, replace])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        let content = NSStackView(views: [text, keyField, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        for view in [text, keyField, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        window.initialFirstResponder = keyField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(over host: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        host.beginSheet(window!)
    }

    @objc private func replace() {
        let key = keyField.stringValue
        guard !key.isEmpty else { NSSound.beep(); return }
        keyField.stringValue = ""
        dismiss(key)
    }

    @objc private func cancel() {
        keyField.stringValue = ""
        dismiss(nil)
    }

    private func dismiss(_ key: String?) {
        guard let sheet = window, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
        sheet.orderOut(nil)
        completion?(key)
        completion = nil
    }
}

@MainActor
private final class RenameConnectionSheetController: NSWindowController {
    private let nameField: NSTextField
    private var completion: ((String?) -> Void)?

    init(profile: ConnectionProfile) {
        nameField = NSTextField(string: profile.name)
        let window = ConnectionSetupSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Rename Connection"
        window.onCancel = { [weak self] in self?.cancel() }
        let root = NSView()
        window.contentView = root
        let prompt = NSTextField(labelWithString: "Connection name")
        nameField.setAccessibilityLabel("Connection name")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        let content = NSStackView(views: [prompt, nameField, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        for view in [nameField, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        window.initialFirstResponder = nameField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(over host: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        host.beginSheet(window!)
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { NSSound.beep(); return }
        dismiss(name)
    }

    @objc private func cancel() { dismiss(nil) }

    private func dismiss(_ name: String?) {
        guard let sheet = window, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
        sheet.orderOut(nil)
        completion?(name)
        completion = nil
    }
}
