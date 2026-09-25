import AppKit
import ProjectLibrary
import EditorCore

@MainActor final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls); return true
    }
}

@MainActor final class ProjectTableView: NSTableView {
    var onContextRow: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onContextRow?(row)
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), selectedRow >= 0, let doubleAction {
            NSApp.sendAction(doubleAction, to: target, from: self)
        } else { super.keyDown(with: event) }
    }
}

@MainActor final class ProjectMenuButton: NSButton {
    var projectID: UUID?
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    var library: ProjectLibrary!
    var window: NSWindow!
    private let themeStore = EditorThemeStore.shared
    private var themeSettingsWindowController: ThemeSettingsWindowController?
    let table = ProjectTableView()
    let search = NSSearchField()
    var rows: [Project] = []
    var workspaces: [UUID: WorkspaceWindow] = [:]
    private var updater: AppUpdater!
    private var terminationInProgress = false
    private var activeWorkspace: WorkspaceWindow? {
        workspaces.values.first { $0.window === NSApp.keyWindow }
    }
    var selected: Project? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    func applicationDidFinishLaunching(_ notification: Notification) {
        switch UserDefaults.standard.integer(forKey: "FSCode.workspace.appearance") {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        do { library = try ProjectLibrary() } catch {
            show(error); NSApp.terminate(nil); return
        }
        updater = AppUpdater()
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FS Code — Projects"
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 740, height: 420)
        window.isReleasedWhenClosed = false
        let root = DropView()
        root.onDrop = { [weak self] in self?.add($0) }
        window.contentView = root
        let heading = NSTextField(labelWithString: "Projects")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        search.placeholderString = "Search Projects"
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openProject(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.onContextRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else { return }
            let id = self.rows[row].id
            self.assign(id, to: self.table.menu)
        }
        table.menu = projectMenu()
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let openFolder = NSButton(title: "Open Folder…", target: self, action: #selector(chooseFolders))
        openFolder.bezelStyle = .rounded
        let controls = NSStackView(views: [heading, NSView(), openFolder])
        controls.spacing = 10
        controls.setHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [controls, search, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 28), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor), search.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.presentNextMissingThemeSelectionNotice() }
    }
    func buildMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About FS Code", action: #selector(showAboutPanel), keyEquivalent: "")
        about.target = self
        let checkForUpdates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        checkForUpdates.toolTip = updater.unavailableReason
        checkForUpdates.isEnabled = updater.canCheckForUpdates
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showThemeSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(withTitle: "Quit FS Code", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); main.addItem(file); file.submenu = NSMenu(title: "File")
        let newWindow = file.submenu!.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        newWindow.target = self
        file.submenu!.addItem(.separator())
        let add = file.submenu!.addItem(withTitle: "Add Project…", action: #selector(chooseFolders), keyEquivalent: "o"); add.target = self
        let addPath = file.submenu!.addItem(withTitle: "Add Folder by Path…", action: #selector(addFolderByPath), keyEquivalent: "O"); addPath.target = self
        let libraryItem = file.submenu!.addItem(withTitle: "Project Library", action: #selector(showLibrary), keyEquivalent: "l"); libraryItem.target = self
        let switchProject = file.submenu!.addItem(withTitle: "Switch Project…", action: #selector(switchProject), keyEquivalent: "L")
        switchProject.target = self
        let closeProject = file.submenu!.addItem(withTitle: "Close Project", action: #selector(closeProject), keyEquivalent: "W")
        closeProject.target = self
        file.submenu!.addItem(.separator())
        let save = file.submenu!.addItem(withTitle: "Save", action: #selector(saveActiveDocument), keyEquivalent: "s")
        save.target = self
        let close = file.submenu!.addItem(withTitle: "Close", action: #selector(closeActiveDocument), keyEquivalent: "w")
        close.target = self
        let edit = NSMenuItem(); main.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        edit.submenu!.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu!.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.submenu!.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu!.addItem(.separator())
        let find = edit.submenu!.addItem(withTitle: "Find…", action: #selector(findInDocument), keyEquivalent: "f")
        find.target = self
        let view = NSMenuItem(); main.addItem(view)
        let viewMenu = NSMenu(title: "View"); view.submenu = viewMenu
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = NSMenu(title: "Appearance")
        for (tag, title) in ["System", "Light", "Dark"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.tag = tag; item.target = self
            appearance.submenu!.addItem(item)
        }
        let terminal = viewMenu.addItem(withTitle: "Show Terminal", action: #selector(toggleTerminalPanel), keyEquivalent: "`")
        terminal.keyEquivalentModifierMask = [.control]
        terminal.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(appearance)
        viewMenu.addItem(.separator())
        let reset = viewMenu.addItem(withTitle: "Reset Layout", action: #selector(resetWorkspaceLayout), keyEquivalent: "")
        reset.target = self
        let window = NSMenuItem(); main.addItem(window)
        let windowMenu = NSMenu(title: "Window")
        window.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    @objc private func showAboutPanel() {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let creditsAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.text(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let credits = NSMutableAttributedString(string: "Created by Daniel Lares with Codex.\n\n", attributes: creditsAttributes)
        appendCreditLink(to: credits, title: "MIT License", resource: "LICENSE")
        credits.append(NSAttributedString(string: "\n", attributes: creditsAttributes))
        appendCreditLink(to: credits, title: "Third-Party Notices", resource: "ThirdPartyNotices")

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "FS Code",
            .applicationVersion: "\(shortVersion) Alpha",
            .credits: credits
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc private func checkForUpdates(_ sender: Any?) { updater.checkForUpdates(sender) }
    private func presentNextMissingThemeSelectionNotice() {
        guard let hostWindow = activeWorkspace?.window ?? window else { return }
        guard hostWindow.attachedSheet == nil else { return }
        guard let notice = themeStore.consumeMissingSelectionNotice() else { return }
        let alert = NSAlert()
        alert.messageText = "Theme Unavailable"
        alert.informativeText = notice
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: hostWindow) { [weak self] _ in
            self?.presentNextMissingThemeSelectionNotice()
        }
    }
    @objc private func showThemeSettings() {
        if themeSettingsWindowController == nil {
            themeSettingsWindowController = ThemeSettingsWindowController(store: themeStore)
        }
        themeSettingsWindowController?.show()
    }
    private func appendCreditLink(to credits: NSMutableAttributedString, title: String, resource: String) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.text(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if let url = Bundle.main.url(forResource: resource, withExtension: "txt") { attributes[.link] = url }
        credits.append(NSAttributedString(string: title, attributes: attributes))
    }
    @objc private func changeAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "FSCode.workspace.appearance")
        switch sender.tag {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    @objc private func resetWorkspaceLayout() {
        workspaces.values.first { $0.window === NSApp.keyWindow }?.resetLayout()
    }
    @objc private func toggleTerminalPanel() { activeWorkspace?.toggleTerminal() }
    @objc private func saveActiveDocument() { activeWorkspace?.saveActive() }
    @objc private func closeActiveDocument() {
        if let activeWorkspace { activeWorkspace.closeActive() }
        else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc private func switchProject() { closeProject() }
    @objc private func closeProject() {
        guard let workspace = activeWorkspace, workspace.canCloseProject else { return }
        // Use the window delegate's existing save/cancel flow for files and TODOs.
        // The library is shown only by onClose after that flow succeeds.
        workspace.window.performClose(nil)
    }
    @objc private func findInDocument() { activeWorkspace?.findInFile() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return updater.canCheckForUpdates }
        if menuItem.action == #selector(toggleTerminalPanel) {
            menuItem.title = activeWorkspace?.isTerminalVisible == true ? "Hide Terminal" : "Show Terminal"
            return activeWorkspace?.canToggleTerminal ?? false
        }
        if menuItem.action == #selector(switchProject) || menuItem.action == #selector(closeProject) {
            return !terminationInProgress && (activeWorkspace?.canCloseProject ?? false)
        }
        if menuItem.action == #selector(saveActiveDocument) { return activeWorkspace?.canSave ?? false }
        if menuItem.action == #selector(findInDocument) { return activeWorkspace?.canFind ?? false }
        if menuItem.action == #selector(closeActiveDocument) { return NSApp.keyWindow != nil && NSApp.keyWindow?.attachedSheet == nil }
        if menuItem.action == #selector(changeAppearance(_:)) {
            menuItem.state = menuItem.tag == UserDefaults.standard.integer(forKey: "FSCode.workspace.appearance") ? .on : .off
        }
        if menuItem.action == #selector(resetWorkspaceLayout) {
            return workspaces.values.contains { $0.window === NSApp.keyWindow }
        }
        return true
    }
    @objc private func newWindow() { showLibrary() }
    @objc func showLibrary() { refresh(); window.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let workspace = activeWorkspace ?? workspaces.values.first {
            workspace.window.makeKeyAndOrderFront(nil)
        } else {
            showLibrary()
        }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard library != nil else { return }
        refresh()
        themeStore.reload()
        presentNextMissingThemeSelectionNotice()
    }
    func applicationWillTerminate(_ notification: Notification) {
        for workspace in workspaces.values { workspace.saveLayout(); workspace.shutdownTerminal() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("FSCode termination: request received")
        guard !terminationInProgress else {
            NSLog("FSCode termination: another termination request is still pending")
            return .terminateCancel
        }
        terminationInProgress = true
        let windows = Array(workspaces.values)
        NSLog("FSCode termination: preparing %ld workspace(s)", windows.count)
        Task {
            for (index, workspace) in windows.enumerated() {
                NSLog("FSCode termination: preparing workspace %ld", index)
                guard await workspace.prepareToClose() else {
                    NSLog("FSCode termination: workspace %ld declined close", index)
                    terminationInProgress = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            for (index, workspace) in windows.enumerated() {
                NSLog("FSCode termination: shutting down assistant %ld", index)
                await workspace.shutdownAssistant()
                NSLog("FSCode termination: assistant %ld stopped", index)
            }
            NSLog("FSCode termination: replying with approval")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func show(_ error: Error) { NSAlert(error: error).runModal() }
    func perform(_ operation: () throws -> Void) { do { try operation(); refresh() } catch { show(error) } }
    @objc func refresh() {
        let id = selected?.id
        rows = library.search(search.stringValue, favoritesOnly: false)
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = rows[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Project folder")!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        let unavailable = !library.isAvailable(project) ? "  · Folder unavailable" : ""
        let title = NSTextField(labelWithString: "\(project.isFavorite ? "★ " : "")\(project.name)\(unavailable)")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let path = NSTextField(labelWithString: library.url(for: project).path)
        path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, path]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = ProjectMenuButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Project actions")!, target: self, action: #selector(showProjectMenu(_:)))
        more.bezelStyle = .texturedRounded
        more.isBordered = false
        more.image = more.image?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        more.imageScaling = .scaleNone
        more.heightAnchor.constraint(equalToConstant: 28).isActive = true
        more.projectID = project.id
        more.toolTip = "Project Actions"
        more.setAccessibilityLabel("Actions for \(project.name)")
        more.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let rowView = NSTableCellView()
        for view in [icon, labels, more] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rowView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
            more.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            title.widthAnchor.constraint(equalTo: labels.widthAnchor),
            path.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])
        return rowView
    }
    private func projectMenu(for projectID: UUID? = nil) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Open", #selector(openProject(_:))),
            ("Edit Name and Tags…", #selector(editProject(_:))),
            ("Toggle Favorite", #selector(toggleFavorite(_:))),
            ("Show in Finder", #selector(reveal(_:))),
            ("Copy Path", #selector(copyPath(_:))),
            ("Locate Folder…", #selector(relocate(_:))),
            ("Remove from Library", #selector(remove(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = projectID
            menu.addItem(item)
        }
        return menu
    }
    private func assign(_ projectID: UUID, to menu: NSMenu?) {
        menu?.items.forEach { $0.representedObject = projectID }
    }
    private func project(for sender: Any?) -> Project? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UUID {
            return rows.first { $0.id == id }
        }
        if let id = (sender as? ProjectMenuButton)?.projectID {
            return rows.first { $0.id == id }
        }
        return selected
    }
    @objc private func showProjectMenu(_ sender: ProjectMenuButton) {
        guard let projectID = sender.projectID else { return }
        let menu = projectMenu(for: projectID)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        guard let hostWindow = activeWorkspace?.window ?? window else { return }
        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }
    @objc private func addFolderByPath() {
        let alert = NSAlert()
        alert.messageText = "Add Folder by Path"
        alert.informativeText = "Enter the path to an existing folder."
        let field = NSTextField(string: "")
        field.placeholderString = "~/Sites/my-project"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = (field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { show(LibraryError.notDirectory); return }
        add([URL(fileURLWithPath: path)])
    }
    private func requestedName(for url: URL, suggestedName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Add Project"
        alert.informativeText = "Choose a display name for this folder. The folder itself will not be renamed."
        let field = NSTextField(string: suggestedName)
        field.placeholderString = "Project Name"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func add(_ urls: [URL]) {
        for url in urls {
            let suggestedName: String
            do { suggestedName = try library.suggestedName(for: url) } catch { show(error); continue }
            guard let name = requestedName(for: url, suggestedName: suggestedName) else { continue }
            do {
                let project = try library.add(url, named: name)
                refresh()
                open(project)
            } catch { show(error) }
        }
    }
    @objc func openProject(_ sender: Any? = nil) {
        guard let project = project(for: sender) else { return }
        open(project)
    }
    private func open(_ project: Project) {
        guard library.isAvailable(project) else { relocateProject(project); return }
        perform {
            try library.markOpened(project)
            if let existing = workspaces[project.id] {
                window.orderOut(nil)
                existing.window.makeKeyAndOrderFront(nil)
                return
            }
            let workspace = WorkspaceWindow(project: project, url: library.url(for: project))
            workspace.onClose = { [weak self] in
                guard let self else { return }
                self.workspaces.removeValue(forKey: project.id)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminationInProgress else { return }
                    self.showLibrary()
                }
            }
            workspaces[project.id] = workspace
            window.orderOut(nil)
            workspace.window.makeKeyAndOrderFront(nil)
        }
    }
    @objc func editProject(_ sender: Any? = nil) {
        guard var project = project(for: sender) else { return }
        let alert = NSAlert(); alert.messageText = "Edit Project"; alert.informativeText = "The display name does not rename the folder. Separate tags with commas."
        let name = NSTextField(string: project.name); let tags = NSTextField(string: project.tags.joined(separator: ", "))
        name.placeholderString = "Name"; tags.placeholderString = "Tags"
        let stack = NSStackView(views: [name, tags]); stack.orientation = .vertical; stack.spacing = 12; stack.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        name.widthAnchor.constraint(equalToConstant: 360).isActive = true; tags.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = stack; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        project.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        project.tags = Array(Set(tags.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        perform { try library.update(project) }
    }
    @objc func toggleFavorite(_ sender: Any? = nil) { guard var project = project(for: sender) else { return }; project.isFavorite.toggle(); perform { try library.update(project) } }
    @objc func reveal(_ sender: Any? = nil) { guard let project = project(for: sender) else { return }; NSWorkspace.shared.activateFileViewerSelecting([library.url(for: project)]) }
    @objc func copyPath(_ sender: Any? = nil) { guard let project = project(for: sender) else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(library.url(for: project).path, forType: .string) }
    @objc func remove(_ sender: Any? = nil) { guard let project = project(for: sender) else { return }; perform { try library.remove(project.id) } }
    @objc func relocate(_ sender: Any? = nil) {
        guard let project = project(for: sender) else { return }
        relocateProject(project)
    }
    private func relocateProject(_ project: Project) {
        let panel = NSOpenPanel(); panel.message = "Locate the folder for \(project.name)"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { perform { try library.relocate(project, to: url) } }
    }
}

@main struct FSCodeApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
