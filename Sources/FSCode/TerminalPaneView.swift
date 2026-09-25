import AppKit
import Darwin
import EditorCore
import SwiftTerm

/// A single, project-scoped terminal session. The owner decides when it starts
/// and when it is safe to shut it down; hiding this view never changes the process.
@MainActor
final class TerminalPaneView: NSView, LocalProcessTerminalViewDelegate {
    var onHide: (() -> Void)?

    private let projectURL: URL
    private let header = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Terminal")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let hideButton = NSButton()
    private let restartButton = NSButton()
    private var terminal: LocalProcessTerminalView
    private var shellName = "zsh"
    private var didStart = false
    private var didExit = false
    private var isShuttingDown = false
    private var shellIntegration: ShellIntegration?
    private let themeStore = EditorThemeStore.shared
    private var themeObserver: NSObjectProtocol?

    init(projectURL: URL) {
        self.projectURL = projectURL.standardizedFileURL
        terminal = Self.makeTerminal()
        super.init(frame: .zero)
        themeObserver = NotificationCenter.default.addObserver(
            forName: .editorThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPalette() }
        }
        setupView()
        applyPalette()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    var isTerminalFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === terminal { return true }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: terminal)
    }

    var hasForegroundJob: Bool {
        guard terminal.process.running else { return false }
        let fd = terminal.process.childfd
        let shellPID = terminal.process.shellPid
        guard fd >= 0, shellPID > 1 else { return false }
        let foregroundGroup = tcgetpgrp(fd)
        return foregroundGroup > 1 && foregroundGroup != shellPID
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        didExit = false
        isShuttingDown = false
        restartButton.isEnabled = false

        let shell = loginShell()
        shellName = URL(fileURLWithPath: shell).lastPathComponent
        shellIntegration?.remove()
        let inherited = Self.shellEnvironment()
        shellIntegration = ShellIntegration.make(for: shell)
        statusLabel.stringValue = "Starting \(shellName)…"
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: terminalEnvironment(inherited: inherited),
            currentDirectory: projectURL.path
        )

        // forkpty can fail without producing output. Surface that state instead
        // of leaving an inert terminal that appears to be working.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.didStart, !self.didExit else { return }
            if self.terminal.process.running {
                self.statusLabel.stringValue = "\(self.shellName) · Running"
            } else {
                self.didExit = true
                self.statusLabel.stringValue = "Could not start \(self.shellName)"
                self.restartButton.isEnabled = true
            }
        }
    }

    func focusTerminal() {
        guard !terminal.isHidden else { return }
        window?.makeFirstResponder(terminal)
    }

    func shutdown() {
        shellIntegration?.remove()
        shellIntegration = nil
        guard terminal.process.running else { return }
        isShuttingDown = true
        let shellPID = terminal.process.shellPid
        let fd = terminal.process.childfd

        // Only signal the job group attached to our own PTY session. This avoids
        // touching an unrelated process group if a descriptor has gone stale.
        let foregroundGroup = fd >= 0 ? tcgetpgrp(fd) : -1
        if foregroundGroup > 1,
           foregroundGroup != getpgrp(),
           getsid(foregroundGroup) == shellPID {
            _ = kill(-foregroundGroup, SIGHUP)
        }
        if shellPID > 1, getsid(shellPID) == shellPID {
            _ = kill(shellPID, SIGHUP)
        }
        terminal.terminate()
        didExit = true
        statusLabel.stringValue = "Session closed"
        restartButton.isEnabled = false
    }

    func find() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminal.performTextFinderAction(item)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let sourceID = ObjectIdentifier(source)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShuttingDown, ObjectIdentifier(self.terminal) == sourceID else { return }
            self.didExit = true
            self.shellIntegration?.remove()
            self.shellIntegration = nil
            // SwiftTerm forwards waitpid's raw status; showing it would turn a
            // normal exit code such as 7 into the misleading value 1792.
            self.statusLabel.stringValue = exitCode == nil ? "\(self.shellName) · Ended" : "\(self.shellName) · Exited"
            self.restartButton.isEnabled = true
        }
    }

    // MARK: View setup

    private static func makeTerminal() -> LocalProcessTerminalView {
        var options = TerminalOptions.default
        options.scrollback = 2_000
        options.enableSixelReported = false
        return LocalProcessTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .followsWindowActiveState
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        configureIconButton(hideButton, symbol: "chevron.down", label: "Hide Terminal", target: self, action: #selector(hideTerminal), pointSize: 12, isBordered: false)
        configureIconButton(restartButton, symbol: "arrow.clockwise", label: "Restart Terminal", target: self, action: #selector(restartTerminal), pointSize: 12, isBordered: false)
        restartButton.isEnabled = false

        [header, terminal].forEach { addSubview($0) }
        [titleLabel, statusLabel, restartButton, hideButton].forEach { header.addSubview($0) }
        [titleLabel, statusLabel, restartButton, hideButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.processDelegate = self

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: restartButton.leadingAnchor, constant: -8),
            hideButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -7),
            hideButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            restartButton.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -2),
            restartButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @objc private func hideTerminal() {
        onHide?()
    }

    @objc private func restartTerminal() {
        guard didExit, !terminal.process.running else { return }
        shellIntegration?.remove()
        shellIntegration = nil
        terminal.removeFromSuperview()
        terminal = Self.makeTerminal()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.processDelegate = self
        addSubview(terminal, positioned: .below, relativeTo: header)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        applyPalette()
        didStart = false
        isShuttingDown = false
        layoutSubtreeIfNeeded()
        startIfNeeded()
        focusTerminal()
    }

    private func applyPalette() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = EditorPalette(theme: themeStore.activeTheme(forDarkAppearance: dark))
        let ansi = palette.ansiColors.map(Self.terminalColor)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = palette.background.cgColor
        }
        terminal.nativeBackgroundColor = palette.background
        terminal.nativeForegroundColor = palette.foreground
        terminal.caretColor = palette.cursor
        terminal.caretTextColor = palette.background
        terminal.selectedTextBackgroundColor = .selectedTextBackgroundColor
        terminal.selectedTextForegroundColor = palette.foreground
        terminal.installColors(ansi)
    }

    private static func terminalColor(_ color: NSColor) -> Color {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return Color(
            red: UInt16((rgb.redComponent * 65_535).rounded()),
            green: UInt16((rgb.greenComponent * 65_535).rounded()),
            blue: UInt16((rgb.blueComponent * 65_535).rounded())
        )
    }

    private func terminalEnvironment(inherited: [String: String]) -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        var replacements = ["TERM_PROGRAM": "FSCode", "COLORTERM": "truecolor"]
        for key in ["ZDOTDIR", "NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "LSCOLORS", "LS_COLORS"] {
            if let value = inherited[key] { replacements[key] = value }
        }
        if replacements["NO_COLOR"] == nil, replacements["CLICOLOR"] == nil {
            replacements["CLICOLOR"] = "1"
            replacements["FSCODE_DEFAULT_CLICOLOR"] = "1"
        }
        if let shellIntegration {
            for entry in shellIntegration.environmentEntries(from: inherited) {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                replacements[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
            }
        }
        environment.removeAll { entry in
            guard let key = entry.split(separator: "=", maxSplits: 1).first else { return false }
            return replacements[String(key)] != nil
        }
        environment.append(contentsOf: replacements.map { "\($0.key)=\($0.value)" })
        return environment
    }

    private static func shellEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        return Dictionary(uniqueKeysWithValues: ["ZDOTDIR", "NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "LSCOLORS", "LS_COLORS"].compactMap { key in
            environment[key].map { (key, $0) }
        })
    }

    private func loginShell() -> String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }
}
