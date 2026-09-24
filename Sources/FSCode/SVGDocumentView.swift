import AppKit

/// Keeps one text editor alive while switching between source and a native
/// document preview. Preview always reads the live buffer and never changes its
/// undo manager or persisted contents.
@MainActor class DocumentPreviewView: NSView {
    enum Kind { case svg, markdown }

    var onModeChange: (() -> Void)?
    private(set) var isShowingPreview = false

    private let editor: NSScrollView
    private let preview: NSView
    private let source: () -> String
    private let kind: Kind

    init(editor: NSScrollView, source: @escaping () -> String, kind: Kind) {
        self.editor = editor
        self.source = source
        self.kind = kind
        switch kind {
        case .svg: preview = ImagePreviewView(frame: .zero)
        case .markdown: preview = MarkdownPreviewView(frame: .zero)
        }
        super.init(frame: .zero)
        for view in [editor, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
            preview.topAnchor.constraint(equalTo: editor.topAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Apply both visibility states directly. Markdown begins in source mode,
        // so relying on a state transition here would leave both views visible.
        isShowingPreview = kind == .svg
        editor.isHidden = isShowingPreview
        preview.isHidden = !isShowingPreview
        if isShowingPreview {
            (preview as? ImagePreviewView)?.showSVG(source: source())
        }
    }

    required init?(coder: NSCoder) { nil }

    func showCode() { setShowingPreview(false) }
    func showPreview() { setShowingPreview(true) }

    private func setShowingPreview(_ showingPreview: Bool) {
        guard isShowingPreview != showingPreview else { return }
        isShowingPreview = showingPreview
        // Remove focus from the hidden editor, retaining selection and undo.
        window?.makeFirstResponder(nil)
        editor.isHidden = isShowingPreview
        preview.isHidden = !isShowingPreview
        if isShowingPreview {
            switch kind {
            case .svg: (preview as? ImagePreviewView)?.showSVG(source: source())
            case .markdown: (preview as? MarkdownPreviewView)?.showMarkdown(source: source())
            }
        }
        onModeChange?()
    }
}

/// Compatibility name for existing SVG preview users and tests.
typealias SVGDocumentView = DocumentPreviewView
