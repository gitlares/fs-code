import AppKit
import ProjectLibrary

@MainActor final class ProjectTodosView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let detailView: TodoDetailView
    /// Called only for a validated inline-comment TODO, with its source line.
    var onOpenFile: ((URL, Int) -> Void)?
    private enum Row { case header(String), todo(ProjectTodo), more(Bool), empty }
    private let projectURL: URL
    private var store: ProjectTodos?
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private let orderControl = NSPopUpButton()
    private var rows: [Row] = []
    private var selectedID: UUID?
    private var openLimit = 10
    private var closedLimit = 10
    private var updatingSelection = false
    private var order: TodoSortOrder {
        switch orderControl.indexOfSelectedItem {
        case 1: .newest
        case 2: .oldest
        default: .relevance
        }
    }

    init(projectURL: URL) {
        self.projectURL = projectURL
        detailView = TodoDetailView(projectURL: projectURL)
        super.init(frame: .zero)
        detailView.onSave = { [weak self] in self?.save($0) ?? false }
        detailView.onDelete = { [weak self] in self?.remove($0) ?? false }
        detailView.onOpenFile = { [weak self] todo in
            guard let self, let store else { return }
            do {
                guard let source = try store.inlineSource(for: todo) else { return }
                onOpenFile?(source.url, source.location.line)
            } catch { NSAlert(error: error).runModal() }
        }
        let refresh = NSButton()
        for (button, symbol, label, action) in [
            (addButton, "plus", "New TODO", #selector(addTodo)),
            (refresh, "arrow.clockwise", "Refresh TODOs", #selector(reload))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = action
        }
        let controls = NSStackView(views: [addButton, refresh])
        controls.spacing = 6
        orderControl.addItems(withTitles: ["Priority", "Newest First", "Oldest First"])
        orderControl.setAccessibilityLabel("Sort TODOs")
        orderControl.toolTip = "Sort TODOs"
        orderControl.target = self
        orderControl.action = #selector(changeOrder)
        table.addTableColumn(NSTableColumn(identifier: .init("todo")))
        table.headerView = nil
        table.rowHeight = 24
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Project TODOs")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        for view in [controls, orderControl, scroll, summary] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            controls.topAnchor.constraint(equalTo: topAnchor),
            orderControl.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            orderControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            orderControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: orderControl.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -8),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        addButton.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc func reload() {
        guard detailView.canLeave() else { return }
        do {
            if let store { try store.reload() }
            else { store = try ProjectTodos(projectURL: projectURL) }
            rebuildRows()
            detailView.show(store?.items.first { $0.id == selectedID })
        } catch {
            store = nil
            rows = []
            table.reloadData()
            detailView.show(nil)
            summary.stringValue = error.localizedDescription
        }
        addButton.isEnabled = store != nil
    }

    private func rebuildRows() {
        let items = store?.items ?? []
        rows = []
        for (completed, title, limit) in [(false, "Open", openLimit), (true, "Closed", closedLimit)] {
            let total = items.filter { $0.isCompleted == completed }.count
            let page = TodoList.page(items, completed: completed, order: order, limit: limit)
            rows.append(.header("\(title) (\(total))"))
            rows.append(contentsOf: page.map(Row.todo))
            if total == 0 { rows.append(.empty) }
            if total > page.count { rows.append(.more(completed)) }
        }
        updatingSelection = true
        table.reloadData()
        restoreSelection()
        updatingSelection = false
        summary.stringValue = items.isEmpty ? "Use + to add your first TODO." : "\(items.count) TODOs"
    }

    private func restoreSelection() {
        if let row = rows.firstIndex(where: {
            if case .todo(let todo) = $0 { return todo.id == selectedID }
            return false
        }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }

    private func save(_ todo: ProjectTodo) -> Bool {
        guard let store else { return false }
        do {
            try store.save(todo)
            selectedID = todo.id
            rebuildRows()
            return true
        } catch { NSAlert(error: error).runModal(); return false }
    }

    private func remove(_ id: UUID) -> Bool {
        guard let store else { return false }
        do {
            try store.remove(id)
            selectedID = nil
            rebuildRows()
            return true
        } catch { NSAlert(error: error).runModal(); return false }
    }

    @objc private func addTodo() {
        guard store != nil, detailView.canLeave() else { return }
        selectedID = nil
        rebuildRows()
        detailView.beginNew()
    }

    @objc private func changeOrder() {
        openLimit = 10
        closedLimit = 10
        rebuildRows()
    }

    @objc private func loadMore(_ sender: NSButton) {
        if sender.tag == 0 { openLimit += 10 } else { closedLimit += 10 }
        rebuildRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .todo = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, rows.indices.contains(table.selectedRow), case .todo(let todo) = rows[table.selectedRow] else { return }
        guard todo.id != selectedID else { return }
        guard detailView.canLeave() else {
            updatingSelection = true
            restoreSelection()
            updatingSelection = false
            return
        }
        selectedID = todo.id
        detailView.show(todo)
        updatingSelection = true
        restoreSelection()
        updatingSelection = false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .more(let closed):
            let button = NSButton(title: "Load More", target: self, action: #selector(loadMore(_:)))
            button.tag = closed ? 1 : 0
            button.bezelStyle = .inline
            button.setAccessibilityLabel(closed ? "Load More Closed TODOs" : "Load More Open TODOs")
            return button
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .empty:
            let label = NSTextField(labelWithString: "No TODOs")
            label.textColor = .tertiaryLabelColor
            return label
        case .todo(let todo):
            let label = NSTextField(labelWithString: todo.title)
            label.font = .systemFont(ofSize: 13)
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = todo.title
            return label
        }
    }
}
