import AppKit

/// Keeps both sidebar views alive so switching preserves file selection and scroll position.
@MainActor final class ProjectSidebarView: NSVisualEffectView {
    enum Mode { case files, todos, plans, agentContext, permissions }
    private let files = NSScrollView()
    private let todos: ProjectTodosView
    private let agentContextSidebar: NSView
    private let plansSidebar: NSView
    private let permissionsSidebar: NSView
    private let heading = NSTextField(labelWithString: "Files")
    private var selector = NSSegmentedControl()
    var onViewChanged: ((Mode) -> Void)?
    var requestLeaveAgentContext: ((@escaping (Bool) -> Void) -> Void)?
    var requestLeavePlans: ((@escaping (Bool) -> Void) -> Void)?
    var onOpenFile: ((URL, Int) -> Void)? {
        didSet { todos.onOpenFile = onOpenFile }
    }
    var todoDetailView: TodoDetailView { todos.detailView }
    private(set) var mode: Mode = .files
    var showsTodos: Bool { mode == .todos }

    init(outline: NSOutlineView, projectURL: URL, agentContextSidebar: NSView, plansSidebar: NSView, permissionsSidebar: NSView) {
        todos = ProjectTodosView(projectURL: projectURL)
        self.agentContextSidebar = agentContextSidebar
        self.plansSidebar = plansSidebar
        self.permissionsSidebar = permissionsSidebar
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        selector = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "folder", accessibilityDescription: "Files")!,
                NSImage(systemSymbolName: "checklist", accessibilityDescription: "TODOs")!,
                NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Plans")!,
                NSImage(systemSymbolName: "person.crop.rectangle", accessibilityDescription: "Agent Context")!,
                NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Permissions")!
            ],
            trackingMode: .selectOne, target: self, action: #selector(switchView(_:))
        )
        selector.segmentStyle = .texturedRounded
        selector.selectedSegment = 0
        selector.setToolTip("Files", forSegment: 0)
        selector.setToolTip("TODOs", forSegment: 1)
        selector.setToolTip("Plans", forSegment: 2)
        selector.setToolTip("Agent Context", forSegment: 3)
        selector.setToolTip("Permissions", forSegment: 4)
        selector.setWidth(38, forSegment: 0)
        selector.setWidth(38, forSegment: 1)
        selector.setWidth(38, forSegment: 2)
        selector.setWidth(38, forSegment: 3)
        selector.setWidth(38, forSegment: 4)
        selector.setAccessibilityLabel("Sidebar view")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        files.documentView = outline
        files.hasVerticalScroller = true
        files.scrollerStyle = .overlay
        files.autohidesScrollers = true
        files.drawsBackground = false
        todos.isHidden = true
        agentContextSidebar.isHidden = true
        plansSidebar.isHidden = true
        permissionsSidebar.isHidden = true

        for view in [selector, heading, files, todos, plansSidebar, agentContextSidebar, permissionsSidebar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            selector.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            heading.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        ])
        for view in [files, todos, plansSidebar, agentContextSidebar, permissionsSidebar] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc private func switchView(_ sender: NSSegmentedControl) {
        let nextMode = modeForSegment(sender.selectedSegment)
        transition(to: nextMode)
    }

    private func transition(to nextMode: Mode, completion: (() -> Void)? = nil) {
        guard nextMode != mode else { completion?(); return }
        if mode == .todos, nextMode != .todos, !todos.detailView.canLeave() {
            selector.selectedSegment = 1
            return
        }
        if mode == .agentContext, nextMode != .agentContext, let requestLeaveAgentContext {
            selector.selectedSegment = 2
            requestLeaveAgentContext { [weak self] allowed in
                guard let self, allowed else { return }
                self.apply(nextMode)
                completion?()
            }
            return
        }
        if mode == .plans, nextMode != .plans, let requestLeavePlans {
            selector.selectedSegment = 2
            requestLeavePlans { [weak self] allowed in
                guard let self, allowed else { return }
                self.apply(nextMode)
                completion?()
            }
            return
        }
        apply(nextMode)
        completion?()
    }

    private func apply(_ nextMode: Mode) {
        mode = nextMode
        selector.selectedSegment = segment(for: nextMode)
        files.isHidden = nextMode != .files
        todos.isHidden = nextMode != .todos
        agentContextSidebar.isHidden = nextMode != .agentContext
        plansSidebar.isHidden = nextMode != .plans
        permissionsSidebar.isHidden = nextMode != .permissions
        heading.stringValue = switch nextMode { case .files: "Files"; case .todos: "TODOs"; case .plans: "Plans"; case .agentContext: "Agent Context"; case .permissions: "Permissions" }
        if nextMode == .todos { todos.reload() }
        onViewChanged?(nextMode)
    }

    func showFiles(completion: (() -> Void)? = nil) {
        transition(to: .files, completion: completion)
    }

    func showAgentContext(completion: (() -> Void)? = nil) {
        transition(to: .agentContext, completion: completion)
    }

    private func modeForSegment(_ segment: Int) -> Mode {
        switch segment { case 1: .todos; case 2: .plans; case 3: .agentContext; case 4: .permissions; default: .files }
    }

    private func segment(for mode: Mode) -> Int {
        switch mode { case .files: 0; case .todos: 1; case .plans: 2; case .agentContext: 3; case .permissions: 4 }
    }
}
