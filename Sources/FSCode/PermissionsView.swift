import AppKit
import ApplicationServices
import AgentConnectionCore

@MainActor
final class PermissionsView: NSView {
    private let store: ProjectCapabilityStore
    private let terminal = NSButton(checkboxWithTitle: "Terminal", target: nil, action: nil)
    private let computerUse = NSButton(checkboxWithTitle: "Computer Use", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let accessibility = NSTextField(wrappingLabelWithString: "")

    init(projectURL: URL) {
        store = ProjectCapabilityStore(projectURL: projectURL)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            terminal.state = await store.isEnabled(.developmentCommands) ? .on : .off
            computerUse.state = await store.isEnabled(.computerUse) ? .on : .off
            updateAccessibilityStatus()
            status.stringValue = ""
        }
    }

    private func configure() {
        let description = NSTextField(wrappingLabelWithString: "Enabled for agents in this project. Commands run with your macOS account access; Computer Use can interact with other apps.")
        description.maximumNumberOfLines = 0
        description.textColor = .secondaryLabelColor

        let readSearch = NSTextField(labelWithString: "Read and Search · Available")
        let fileEdits = NSTextField(labelWithString: "File Edits · Available in Build")
        for label in [readSearch, fileEdits] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }

        terminal.target = self
        terminal.action = #selector(changeCapability)
        terminal.setAccessibilityLabel("Allow Terminal for this project")
        computerUse.target = self
        computerUse.action = #selector(changeCapability)
        computerUse.setAccessibilityLabel("Allow Computer Use for this project")

        let requestAccessibility = NSButton(title: "Accessibility Permission…", target: self, action: #selector(requestAccessibilityPermission))
        requestAccessibility.controlSize = .small
        accessibility.font = .systemFont(ofSize: 12)
        accessibility.maximumNumberOfLines = 0
        status.font = .systemFont(ofSize: 12)
        status.textColor = .systemRed
        status.maximumNumberOfLines = 0

        let stack = NSStackView(views: [description, readSearch, fileEdits, terminal, computerUse, accessibility, requestAccessibility, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for label in [description, accessibility, status] {
            label.translatesAutoresizingMaskIntoConstraints = false
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

    @objc private func changeCapability(_ sender: NSButton) {
        let capability: ProjectCapability = sender === terminal ? .developmentCommands : .computerUse
        let requestedState = sender.state == .on
        sender.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.setEnabled(capability, enabled: requestedState)
                status.stringValue = ""
            } catch {
                sender.state = requestedState ? .off : .on
                status.stringValue = "Could not save this project permission: \(error.localizedDescription)"
            }
            sender.isEnabled = true
        }
    }

    @objc private func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        updateAccessibilityStatus()
    }

    @objc private func applicationDidBecomeActive() { updateAccessibilityStatus() }

    private func updateAccessibilityStatus() {
        accessibility.stringValue = AXIsProcessTrusted()
            ? "Accessibility permission is enabled."
            : "Accessibility permission is required for Computer Use."
        accessibility.textColor = AXIsProcessTrusted() ? .secondaryLabelColor : .systemOrange
    }
}
