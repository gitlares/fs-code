import AppKit
import ProjectLibrary

@MainActor final class TodoDetailView: NSView {
    var onSave: ((ProjectTodo) -> Bool)?
    var onDelete: ((UUID) -> Bool)?
    var onOpenFile: ((ProjectTodo) -> Void)?

    private let projectURL: URL
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Select a TODO to see its details.")
    private let titleField = NSTextField()
    private let actionBar = NSView()
    private let contextLabel = NSTextField(labelWithString: "TODO")
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let statusPopup = NSPopUpButton()
    private let relevancePopup = NSPopUpButton()
    private let descriptionView = TodoTextView()
    private let commentsStack = NSStackView()
    private let newCommentView = TodoTextView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let editorScroll = NSScrollView()

    private var loadedTodo: ProjectTodo?
    private var isNew = false

    var canSave: Bool { isNew || loadedTodo != nil }
    func saveChanges() { if canSave { _ = save() } }

    init(projectURL: URL) {
        self.projectURL = projectURL
        super.init(frame: .zero)
        buildView()
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show(_ todo: ProjectTodo?) {
        loadedTodo = todo
        isNew = false
        guard let todo else {
            actionBar.isHidden = true
            editorScroll.isHidden = true
            emptyLabel.isHidden = false
            scrollToTop()
            return
        }
        populate(with: todo)
        actionBar.isHidden = false
        editorScroll.isHidden = false
        emptyLabel.isHidden = true
        scrollToTop()
    }

    func beginNew() {
        loadedTodo = nil
        isNew = true
        contextLabel.stringValue = "New TODO"
        saveButton.title = "Create"
        titleField.stringValue = ""
        statusPopup.selectItem(withTitle: "Open")
        relevancePopup.selectItem(withTitle: "Normal")
        descriptionView.string = ""
        newCommentView.string = ""
        setComments([])
        updateActions()
        actionBar.isHidden = false
        editorScroll.isHidden = false
        emptyLabel.isHidden = true
        scrollToTop()
        window?.makeFirstResponder(titleField)
    }

    /// Returns false when the user cancels leaving or when saving cannot be completed.
    func canLeave() async -> Bool {
        guard isDirty else { return true }
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = "Save changes to TODO?"
        alert.informativeText = "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { continuation.resume(returning: false); return }
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: self.save())
                case .alertSecondButtonReturn:
                    self.show(self.loadedTodo)
                    continuation.resume(returning: true)
                default:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private var isDirty: Bool {
        guard isNew || loadedTodo != nil else { return false }
        let fields = currentValues()
        if isNew {
            return !fields.title.isEmpty || !fields.description.isEmpty || !fields.newComment.isEmpty || fields.isCompleted || fields.relevance != .normal
        }
        guard let loadedTodo else { return false }
        return fields.title != loadedTodo.title
            || fields.description != loadedTodo.description
            || fields.isCompleted != loadedTodo.isCompleted
            || fields.relevance != loadedTodo.relevance
            || !fields.newComment.isEmpty
    }

    private func buildView() {
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        titleField.placeholderString = "Untitled TODO"
        titleField.font = .systemFont(ofSize: 25, weight: .semibold)
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.setAccessibilityLabel("Title")
        statusPopup.addItems(withTitles: ["Open", "Closed"])
        relevancePopup.addItems(withTitles: ["Low", "Normal", "High"])
        for popup in [statusPopup, relevancePopup] {
            popup.bezelStyle = .rounded
            popup.font = .systemFont(ofSize: 13)
        }
        statusPopup.setAccessibilityLabel("Status")
        relevancePopup.setAccessibilityLabel("Priority")
        descriptionView.placeholder = "Add a description…"
        newCommentView.placeholder = "Write a comment…"

        contextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        contextLabel.textColor = .secondaryLabelColor
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        moreButton.isBordered = false
        moreButton.setAccessibilityLabel("More TODO Actions")
        moreButton.toolTip = "More TODO Actions"
        for view in [contextLabel, moreButton, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            actionBar.addSubview(view)
        }
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionBar)

        let status = NSStackView(views: [label("Status"), statusPopup])
        let priority = NSStackView(views: [label("Priority"), relevancePopup])
        for group in [status, priority] {
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 6
        }
        let metadata = NSStackView(views: [status, priority])
        metadata.spacing = 28
        metadata.alignment = .top
        let separator = NSBox()
        separator.boxType = .separator
        let descriptionLabel = label("Description")
        let descriptionBox = textArea(descriptionView, label: "Description", height: 138)
        let commentsLabel = label("Comments")
        let commentBox = textArea(newCommentView, label: "New comment", height: 76)
        commentsStack.orientation = .vertical
        commentsStack.alignment = .leading
        commentsStack.spacing = 20

        let content = TodoContentView(views: [
            titleField, metadata, separator, descriptionLabel, descriptionBox,
            commentsLabel, commentsStack, commentBox
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 28, right: 28)
        content.setCustomSpacing(8, after: descriptionLabel)
        content.setCustomSpacing(10, after: commentsLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.documentView = content
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editorScroll)

        for view in [titleField, metadata, separator, descriptionLabel, descriptionBox, commentsLabel, commentsStack, commentBox] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true
        }
        content.widthAnchor.constraint(equalTo: editorScroll.contentView.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            actionBar.topAnchor.constraint(equalTo: topAnchor),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 50),
            contextLabel.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 28),
            contextLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -24),
            saveButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            moreButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: actionBar.bottomAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func populate(with todo: ProjectTodo) {
        contextLabel.stringValue = "TODO"
        saveButton.title = "Save"
        titleField.stringValue = todo.title
        statusPopup.selectItem(withTitle: todo.isCompleted ? "Closed" : "Open")
        relevancePopup.selectItem(withTitle: relevanceTitle(todo.relevance))
        descriptionView.string = todo.description
        newCommentView.string = ""
        setComments(todo.comments)
        updateActions()
    }

    private func setComments(_ comments: [TodoComment]) {
        commentsStack.arrangedSubviews.forEach { commentsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        commentsStack.isHidden = comments.isEmpty
        if comments.isEmpty { return }
        for comment in comments {
            let date = NSTextField(labelWithString: comment.createdAt.formatted(date: .abbreviated, time: .shortened))
            date.font = .systemFont(ofSize: 11)
            date.textColor = .secondaryLabelColor
            let text = NSTextField(wrappingLabelWithString: comment.text)
            text.font = .systemFont(ofSize: 13)
            let item = NSStackView(views: [text, date])
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = 6
            commentsStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: commentsStack.widthAnchor).isActive = true
            text.widthAnchor.constraint(equalTo: item.widthAnchor).isActive = true
        }
    }

    @objc private func saveClicked() { _ = save() }

    @discardableResult private func save() -> Bool {
        let values = currentValues()
        var todo = loadedTodo ?? ProjectTodo(title: "")
        todo.title = values.title
        todo.description = values.description
        todo.isCompleted = values.isCompleted
        todo.relevance = values.relevance
        if !values.newComment.isEmpty { todo.comments.append(TodoComment(text: values.newComment)) }
        guard onSave?(todo) ?? false else { return false }
        loadedTodo = todo
        isNew = false
        populate(with: todo)
        return true
    }

    @objc private func deleteClicked() {
        guard let todo = loadedTodo, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete TODO?"
        alert.informativeText = "“\(todo.title)” and its comments will be removed. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.onDelete?(todo.id) == true else { return }
            self.show(nil)
        }
    }

    @objc private func openLinkedFile() {
        guard let todo = loadedTodo, inlineSource(for: todo) != nil else { return }
        Task { [weak self] in
            guard let self, await self.canLeave() else { return }
            self.onOpenFile?(todo)
        }
    }

    private func updateActions() {
        moreButton.removeAllItems()
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More TODO Actions")
        moreButton.menu?.autoenablesItems = false
        if let todo = loadedTodo {
            let created = NSMenuItem(title: "Created " + todo.createdAt.formatted(date: .abbreviated, time: .omitted), action: nil, keyEquivalent: "")
            created.isEnabled = false
            moreButton.menu?.addItem(created)
            moreButton.menu?.addItem(.separator())
        }
        var actions: [(String, Selector, Bool)] = []
        if let todo = loadedTodo, inlineSource(for: todo) != nil {
            actions.append(("Open Linked File", #selector(openLinkedFile), true))
        }
        actions.append(("Delete TODO…", #selector(deleteClicked), loadedTodo != nil))
        for (title, action, enabled) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            moreButton.menu?.addItem(item)
        }
    }

    private func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorScroll.layoutSubtreeIfNeeded()
            self.editorScroll.contentView.scroll(to: .zero)
            self.editorScroll.reflectScrolledClipView(self.editorScroll.contentView)
        }
    }

    private func inlineSource(for todo: ProjectTodo) -> (url: URL, line: Int)? {
        guard todo.origin == .inlineComment,
              let path = todo.linkedFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              let line = todo.sourceLocation?.line,
              line > 0 else { return nil }
        let url = projectURL.appendingPathComponent(path).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard url.path.hasPrefix(projectURL.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path),
              values?.isRegularFile == true else { return nil }
        return (url, line)
    }

    private func currentValues() -> (title: String, description: String, newComment: String, isCompleted: Bool, relevance: TodoRelevance) {
        (
            titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionView.string,
            newCommentView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            statusPopup.titleOfSelectedItem == "Closed",
            relevance(from: relevancePopup.titleOfSelectedItem)
        )
    }

    private func label(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private static let textAreaScrollPadding: CGFloat = 8

    private func textArea(_ view: TodoTextView, label: String, height: CGFloat) -> NSBox {
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = Radius.small
        box.contentViewMargins = .zero
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        let growConstraint = box.heightAnchor.constraint(equalToConstant: height)
        growConstraint.priority = .defaultHigh
        growConstraint.isActive = true
        view.onHeightChange = { [weak growConstraint] contentHeight in
            growConstraint?.constant = contentHeight + Self.textAreaScrollPadding
        }
        let container = box.contentView!
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return box
    }

    private func relevanceTitle(_ relevance: TodoRelevance) -> String {
        switch relevance {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    private func relevance(from title: String?) -> TodoRelevance {
        switch title {
        case "Low": .low
        case "High": .high
        default: .normal
        }
    }
}

@MainActor private final class TodoContentView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor private final class TodoTextView: NSTextView {
    var placeholder = ""
    var onHeightChange: ((CGFloat) -> Void)?
    override var string: String {
        didSet {
            needsDisplay = true
            notifyHeightChange()
        }
    }
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        notifyHeightChange()
    }
    private func notifyHeightChange() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        onHeightChange?(ceil(used.height) + textContainerInset.height * 2)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let rect = NSRect(x: textContainerInset.width + padding, y: textContainerInset.height,
                          width: max(0, bounds.width - 24), height: 40)
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: font ?? UIFont.text(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}
