import AppKit
import ApplicationServices
import AgentConnectionCore

@MainActor
final class PermissionsView: NSView {
    private let store: ProjectCapabilityStore

    private let terminalSwitch = NSSwitch()
    private let computerUseSwitch = NSSwitch()
    private let codeIntelligenceSwitch = NSSwitch()
    private let sensitiveFileAccessSwitch = NSSwitch()
    private let networkAccessSwitch = NSSwitch()

    private let accessibilityIcon = NSImageView(image: NSImage(systemSymbolName: "accessibility", accessibilityDescription: nil) ?? NSImage())
    private let accessibilitySubtitle = NSTextField(wrappingLabelWithString: "")
    private let accessibilityButton = NSButton(title: "Open Settings…", target: nil, action: nil)

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(projectURL: URL) {
        store = ProjectCapabilityStore(projectURL: projectURL)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            terminalSwitch.state = await store.isEnabled(.developmentCommands) ? .on : .off
            computerUseSwitch.state = await store.isEnabled(.computerUse) ? .on : .off
            codeIntelligenceSwitch.state = await store.isEnabled(.codeIntelligence) ? .on : .off
            sensitiveFileAccessSwitch.state = await store.isEnabled(.sensitiveFileAccess) ? .on : .off
            networkAccessSwitch.state = await store.isEnabled(.networkAccess) ? .on : .off
            updateAccessibilityStatus()
            statusLabel.stringValue = ""
        }
    }

    private func configure() {
        let description = NSTextField(wrappingLabelWithString: "Control what agents can do in this project. Commands run with your macOS account access; Computer Use can interact with other apps.")
        description.maximumNumberOfLines = 0
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 11)

        for toggle in [terminalSwitch, computerUseSwitch, codeIntelligenceSwitch, sensitiveFileAccessSwitch, networkAccessSwitch] {
            toggle.target = self
            toggle.action = #selector(changeCapability(_:))
            toggle.controlSize = .small
        }
        terminalSwitch.setAccessibilityLabel("Allow Terminal for this project")
        computerUseSwitch.setAccessibilityLabel("Allow Computer Use for this project")
        codeIntelligenceSwitch.setAccessibilityLabel("Allow Code Intelligence for this project")
        sensitiveFileAccessSwitch.setAccessibilityLabel("Allow reading and editing secrets and env files for this project")
        networkAccessSwitch.setAccessibilityLabel("Allow network-reaching commands for this project")

        accessibilityButton.controlSize = .small
        accessibilityButton.bezelStyle = .inline
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibilityPermission)
        accessibilityButton.setAccessibilityLabel("Open Accessibility settings")
        accessibilitySubtitle.font = .systemFont(ofSize: 11)
        accessibilitySubtitle.maximumNumberOfLines = 0

        let alwaysAvailableCard = makeCard(rows: [
            row(symbol: "magnifyingglass", tint: .secondaryLabelColor, title: "Read & Search", subtitle: "Browse files and search this project.", accessory: includedBadge()),
            row(symbol: "pencil", tint: .secondaryLabelColor, title: "File Edits", subtitle: "Available in Build mode.", accessory: includedBadge())
        ])

        let projectCard = makeCard(rows: [
            row(symbol: "terminal", tint: .systemBlue, title: "Terminal", subtitle: "Run local build and test commands with your account access.", accessory: terminalSwitch),
            row(symbol: "cursorarrow.rays", tint: .systemPurple, title: "Computer Use", subtitle: "Let the agent operate other apps on your Mac.", accessory: computerUseSwitch),
            row(symbol: "sparkles", tint: .systemTeal, title: "Code Intelligence", subtitle: "Project-wide symbol search and navigation.", accessory: codeIntelligenceSwitch),
            row(symbol: "key.fill", tint: .systemOrange, title: "Secrets & Env Files", subtitle: ".env, credentials, and keys stay off-limits until enabled.", accessory: sensitiveFileAccessSwitch),
            row(symbol: "network", tint: .systemGreen, title: "Network Access", subtitle: "git push/pull, curl, and installs — separate from Terminal.", accessory: networkAccessSwitch)
        ])

        accessibilityIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        let systemCard = makeCard(rows: [
            row(icon: accessibilityIcon, title: "Accessibility", subtitleView: accessibilitySubtitle, accessory: accessibilityButton)
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [
            description,
            sectionHeader("ALWAYS AVAILABLE"),
            alwaysAvailableCard,
            sectionHeader("PROJECT PERMISSIONS"),
            projectCard,
            sectionHeader("SYSTEM ACCESS"),
            systemCard,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.m
        stack.setCustomSpacing(Spacing.xs, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(Spacing.xs, after: stack.arrangedSubviews[3])
        stack.setCustomSpacing(Spacing.xs, after: stack.arrangedSubviews[5])
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentView.bottomAnchor, constant: -12)
        ])
        for card in [alwaysAvailableCard, projectCard, systemCard] {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for label in [description] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Row and card building blocks

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func includedBadge() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Included") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return icon
    }

    private func row(symbol: String, tint: NSColor, title: String, subtitle: String, accessory: NSView) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint
        let subtitleField = NSTextField(wrappingLabelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 0
        return row(icon: icon, title: title, subtitleView: subtitleField, accessory: accessory)
    }

    private func row(icon: NSImageView, title: String, subtitleView: NSTextField, accessory: NSView) -> NSView {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let textStack = NSStackView(views: [titleLabel, subtitleView])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rowStack = NSStackView(views: [icon, textStack, accessory])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = Spacing.s
        rowStack.distribution = .fill
        rowStack.edgeInsets = NSEdgeInsets(top: Spacing.s, left: Spacing.m, bottom: Spacing.s, right: Spacing.m)
        return rowStack
    }

    private func makeCard(rows: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Radius.medium
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        var interleaved: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { interleaved.append(divider()) }
            interleaved.append(row)
        }

        let stack = NSStackView(views: interleaved)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: - Actions

    @objc private func changeCapability(_ sender: NSSwitch) {
        let capability: ProjectCapability
        if sender === terminalSwitch { capability = .developmentCommands }
        else if sender === computerUseSwitch { capability = .computerUse }
        else if sender === codeIntelligenceSwitch { capability = .codeIntelligence }
        else if sender === sensitiveFileAccessSwitch { capability = .sensitiveFileAccess }
        else { capability = .networkAccess }
        let requestedState = sender.state == .on
        sender.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.setEnabled(capability, enabled: requestedState)
                statusLabel.stringValue = ""
            } catch {
                sender.state = requestedState ? .off : .on
                statusLabel.stringValue = "Could not save this project permission: \(error.localizedDescription)"
            }
            sender.isEnabled = true
        }
    }

    @objc private func requestAccessibilityPermission() {
        _ = AccessibilityPermissionGate.shared.authorize()
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(settingsURL) {
            statusLabel.stringValue = "Could not open System Settings. Open Privacy & Security → Accessibility manually."
        } else {
            statusLabel.stringValue = ""
        }
        updateAccessibilityStatus()
    }

    @objc private func applicationDidBecomeActive() { updateAccessibilityStatus() }

    private func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilitySubtitle.stringValue = trusted
            ? "Enabled — Computer Use can operate other apps."
            : "Required for Computer Use to operate other apps."
        accessibilitySubtitle.textColor = trusted ? .systemGreen : .systemOrange
        accessibilityIcon.contentTintColor = trusted ? .systemGreen : .secondaryLabelColor
    }
}
