import AppKit
import EditorCore
import UniformTypeIdentifiers

/// The application-wide editor color selection. This window deliberately only
/// controls editor and terminal colors; all surrounding application UI retains
/// AppKit semantic colors.
@MainActor
final class ThemeSettingsWindowController: NSWindowController {
    private let store: EditorThemeStore
    private let lightThemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let darkThemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let preview = ThemePreviewView()
    private let contrastWarningIcon = NSImageView()
    private let contrastWarning = NSTextField(wrappingLabelWithString: "")
    private let contrastWarningRow = NSStackView()
    private var previewedVariant: EditorThemeVariant = .light

    init(store: EditorThemeStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 365),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 330)
        super.init(window: window)
        buildContents(in: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeStoreDidChange),
            name: .editorThemeDidChange,
            object: store
        )
        reload()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        // This is a disk refresh boundary. The observer below only redraws UI,
        // so store notifications cannot create a reload cycle.
        store.reload()
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContents(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let description = NSTextField(wrappingLabelWithString: "Choose colors for editors and terminals. These settings do not change the application interface or fonts.")
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        configure(popup: lightThemePopup, label: "Light appearance", action: #selector(selectLightTheme(_:)))
        configure(popup: darkThemePopup, label: "Dark appearance", action: #selector(selectDarkTheme(_:)))

        let selectionGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Light appearance"), lightThemePopup],
            [NSTextField(labelWithString: "Dark appearance"), darkThemePopup]
        ])
        selectionGrid.column(at: 0).xPlacement = .trailing
        selectionGrid.column(at: 1).xPlacement = .fill
        selectionGrid.rowSpacing = 10
        selectionGrid.columnSpacing = 14

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        contrastWarning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contrastWarning.textColor = .secondaryLabelColor
        contrastWarning.maximumNumberOfLines = 2
        contrastWarningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Low contrast warning")
        contrastWarningIcon.contentTintColor = .systemOrange
        contrastWarningIcon.setAccessibilityLabel("Low contrast warning")
        contrastWarningIcon.setContentHuggingPriority(.required, for: .horizontal)
        contrastWarningRow.orientation = .horizontal
        contrastWarningRow.alignment = .firstBaseline
        contrastWarningRow.spacing = 6
        contrastWarningRow.addArrangedSubview(contrastWarningIcon)
        contrastWarningRow.addArrangedSubview(contrastWarning)

        let importButton = NSButton(title: "Import Theme…", target: self, action: #selector(importTheme(_:)))
        importButton.bezelStyle = .rounded
        importButton.setAccessibilityLabel("Import a Base16 theme file")
        let footer = NSStackView(views: [NSView(), importButton])
        footer.orientation = .horizontal

        let previewRow = NSStackView(views: [preview, detailLabel])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 12
        preview.widthAnchor.constraint(equalToConstant: 126).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 44).isActive = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [description, selectionGrid, previewRow, contrastWarningRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selectionGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contrastWarningRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lightThemePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            darkThemePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func configure(popup: NSPopUpButton, label: String, action: Selector) {
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel("Theme for \(label)")
        popup.controlSize = .regular
    }

    @objc private func themeStoreDidChange(_ notification: Notification) { reload() }

    private func reload() {
        populate(lightThemePopup, selectedID: store.selectedThemeID(for: .light))
        populate(darkThemePopup, selectedID: store.selectedThemeID(for: .dark))
        let previewedID = store.selectedThemeID(for: previewedVariant)
        let fallback = store.activeTheme(forDarkAppearance: previewedVariant == .dark)
        updateDetails(theme: store.themes.first { $0.id == previewedID } ?? fallback)
    }

    private func populate(_ popup: NSPopUpButton, selectedID: String?) {
        popup.removeAllItems()
        let availableThemes = store.themes.sorted {
            if $0.variant != $1.variant { return $0.variant == .light }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for theme in availableThemes {
            let author = theme.author.map { " — \($0)" } ?? ""
            let lowContrast = theme.contrastRatio < 4.5
            let warning = lowContrast ? "  Low contrast" : ""
            let item = NSMenuItem(title: "\(theme.name)\(author) · \(theme.variant.rawValue.capitalized)\(warning)", action: nil, keyEquivalent: "")
            item.representedObject = theme.id
            item.toolTip = "\(theme.name), \(theme.variant.rawValue)\(author)\(lowContrast ? ". Foreground contrast is below 4.5:1." : "")"
            if lowContrast {
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Low contrast")?
                    .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            }
            popup.menu?.addItem(item)
        }
        if let selectedID, let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedID }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func selectLightTheme(_ sender: NSPopUpButton) { select(sender, for: .light) }
    @objc private func selectDarkTheme(_ sender: NSPopUpButton) { select(sender, for: .dark) }

    private func select(_ popup: NSPopUpButton, for variant: EditorThemeVariant) {
        guard let id = popup.selectedItem?.representedObject as? String else { return }
        store.setSelectedThemeID(id, for: variant)
        previewedVariant = variant
        updateDetails(theme: store.themes.first { $0.id == id } ?? store.activeTheme(forDarkAppearance: variant == .dark))
    }

    private func updateDetails(theme: EditorTheme) {
        let author = theme.author.map { " by \($0)" } ?? ""
        detailLabel.stringValue = "\(theme.name)\(author) · \(theme.variant.rawValue.capitalized)"
        preview.theme = theme
        if theme.contrastRatio < 4.5 {
            contrastWarning.stringValue = "Warning: foreground contrast is \(String(format: "%.1f", theme.contrastRatio)):1, below the recommended 4.5:1."
            contrastWarningRow.isHidden = false
        } else {
            contrastWarning.stringValue = ""
            contrastWarningRow.isHidden = true
        }
    }

    @objc private func importTheme(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml")!,
            UTType(filenameExtension: "yml")!
        ]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Theme"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.readAndImport(url)
        }
    }

    private func readAndImport(_ url: URL) {
        do {
            let yaml = try String(contentsOf: url, encoding: .utf8)
            let parsed = try Base16ThemeImporter.parse(yaml: yaml)
            let existing = store.themes.first { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }
            if let existing, existing.id.hasPrefix("builtin.") {
                let error = NSError(
                    domain: "FSCode.ThemeImport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The built-in theme \(existing.name) cannot be replaced."]
                )
                presentImportError(error)
            } else if existing != nil {
                let alert = NSAlert()
                alert.messageText = "Replace Theme?"
                alert.informativeText = "A theme named \(parsed.name) already exists. Replace it with the imported file?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window!) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.performImport(yaml, sourceName: url.lastPathComponent, replaceExisting: true)
                }
            } else {
                performImport(yaml, sourceName: url.lastPathComponent, replaceExisting: false)
            }
        } catch {
            presentImportError(error)
        }
    }

    private func performImport(_ yaml: String, sourceName: String, replaceExisting: Bool) {
        do {
            _ = try store.importTheme(yaml: yaml, sourceName: sourceName, replaceExisting: replaceExisting)
            reload()
        } catch {
            presentImportError(error)
        }
    }

    private func presentImportError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window!)
    }
}

@MainActor
private final class ThemePreviewView: NSView {
    var theme: EditorTheme? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        ThemePreviewView.color(theme.background).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).stroke()

        let sample = NSMutableAttributedString(
            string: "let x = 42",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: ThemePreviewView.color(theme.foreground)
            ]
        )
        sample.addAttribute(.foregroundColor, value: ThemePreviewView.color(theme.tokenColor(for: .keyword)), range: NSRange(location: 0, length: 3))
        sample.addAttribute(.foregroundColor, value: ThemePreviewView.color(theme.tokenColor(for: .number)), range: NSRange(location: 8, length: 2))
        let size = sample.size()
        sample.draw(at: NSPoint(x: 10, y: bounds.midY - size.height / 2))
    }

    private static func color(_ rgb: ThemeRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: rgb.alpha)
    }
}
