import AppKit

/// A compact, horizontally scrolling document tab strip for the editor, built on
/// top of the shared `TabStripView`. Filenames stay readable, close actions are
/// separately focusable via hover, and system colours track appearance/accessibility.
@MainActor
final class EditorTabBar: NSView {
    struct Item: TabStripItem {
        let url: URL
        let rawTitle: String
        let isDirty: Bool
        let isAgentModified: Bool

        init(url: URL, title: String, isDirty: Bool, isAgentModified: Bool) {
            self.url = url
            self.rawTitle = title
            self.isDirty = isDirty
            self.isAgentModified = isAgentModified
        }

        var id: URL { url }
        var title: String { rawTitle.isEmpty ? url.lastPathComponent : rawTitle }
    }

    var onSelect: ((URL) -> Void)? {
        didSet { strip.onSelect = onSelect }
    }
    var onClose: ((URL) -> Void)? {
        didSet { strip.onClose = onClose }
    }

    private let strip: TabStripView<Item>

    override init(frame frameRect: NSRect) {
        strip = TabStripView(configuration: TabStripConfiguration(
            icon: { item in
                let image = NSWorkspace.shared.icon(forFile: item.url.path).copy() as? NSImage
                image?.size = NSSize(width: 16, height: 16)
                return image
            },
            tooltip: { $0.url.path },
            accessibilityHelp: { $0.url.path },
            accessories: { item in
                var accessories: Set<TabStripAccessory> = []
                if item.isDirty { accessories.insert(.dirty) }
                if item.isAgentModified { accessories.insert(.agentModified) }
                return accessories
            },
            selectedBackground: { appearance in EditorPalette(appearance: appearance).background },
            minWidth: 110,
            maxWidth: 200,
            chromeWidth: 80,
            horizontalInset: 5,
            showsChrome: true,
            accessibilityGroupLabel: "Open files"
        ))
        super.init(frame: frameRect)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Reconciles the visible tabs with the editor's open documents.
    func update(items: [Item], selectedURL: URL?) {
        strip.update(items: items, selectedID: selectedURL)
    }
}
