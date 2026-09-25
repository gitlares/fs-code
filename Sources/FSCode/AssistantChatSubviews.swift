import AppKit
import AgentConnectionCore

// Supporting cell/row views for `AssistantChatView`'s transcript, queue, and
// composer. Split out from the main file because these types are self-contained
// (each owns its own layout and state); the types below are used directly from
// `AssistantChatView`, so they're `internal` rather than `private` to that file.
// `BlockTarget` stays `private` — it's only used inside `TurnFilesDisclosureView`,
// both of which live in this file.

struct QueueRenderState: Equatable {
    let messages: [ConversationQueuedMessage]
    let isPaused: Bool
    let error: String?
    let canSteer: Bool
    let inFlightID: UUID?
    let isConnected: Bool
}

@MainActor
final class TurnActivityDisclosureView: NSView {
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
            text.backgroundColor = .textBackgroundColor
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
            scroll.backgroundColor = .textBackgroundColor
            scroll.borderType = .lineBorder
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
final class UserMessageSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.medium
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
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 0.5
        }
    }
}

@MainActor
final class CheckpointDisclosureView: NSView {
    private let toggle = NSButton(title: "Task details", target: nil, action: nil)
    private let details = NSStackView()
    private let changed: (Bool) -> Void

    init(checkpoint: AssistantCheckpoint, isExpanded: Bool, changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show task details")
        toggle.imagePosition = .imageLeading
        toggle.target = self
        toggle.action = #selector(toggleDetails)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        let nextAction = checkpoint.meaningfulNextAction ?? ""
        for field in checkpoint.fields {
            let label = NSTextField(wrappingLabelWithString: "\(field.label): \(field.value)")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            details.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        details.isHidden = !isExpanded
        toggle.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        let next = NSTextField(wrappingLabelWithString: nextAction.isEmpty ? "" : "Next: \(nextAction)")
        next.font = .systemFont(ofSize: 12, weight: .medium)
        next.textColor = .secondaryLabelColor
        next.maximumNumberOfLines = 0
        next.isHidden = nextAction.isEmpty
        let stack = NSStackView(views: [toggle, next, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        details.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        next.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func toggleDetails() { details.isHidden.toggle(); toggle.image = NSImage(systemSymbolName: details.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil); changed(!details.isHidden) }
}

final class CopyMessageButton: NSButton {
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
final class AttachmentRemoveButton: NSButton {
    let id: UUID
    init(id: UUID, displayName: String) {
        self.id = id
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
final class AssistantResponseTextView: NSTextView, NSTextViewDelegate {
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
final class TurnFilesDisclosureView: NSView {
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
        restore.hasDestructiveAction = true
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
final class QueuedMessageButton: NSButton {
    let messageID: UUID

    init(messageID: UUID) {
        self.messageID = messageID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
final class AgentChangeOpenButton: NSButton {
    let hunk: AgentFileChangeHunk

    init(hunk: AgentFileChangeHunk) {
        self.hunk = hunk
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
final class ComposerTextView: NSTextView {
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
final class CompactMenuButton: NSButton {
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
