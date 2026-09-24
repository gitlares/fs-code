import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// A read-only tab for files that cannot safely be treated as editor text.
/// Quick Look is only embedded for a conservative group of known document and
/// media types. The fallback deliberately makes no claim that arbitrary bytes
/// can be previewed.
@MainActor
final class BinaryFilePreviewView: NSView {
    enum Reason {
        case binary
        case unsupportedEncoding
        case tooLarge
    }
    private static let officeExtensions: Set<String> = [
        "doc", "docx", "key", "numbers", "pages", "odp", "ods", "odt", "ppt", "pptx", "rtf", "xls", "xlsx"
    ]
    private static let blockedExtensions: Set<String> = [
        "app", "bin", "dylib", "exe", "o", "out", "so"
    ]

    private let fileURL: URL
    private let allowsQuickLook: Bool
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "This file can’t be displayed as text.")
    private let detailLabel = NSTextField(wrappingLabelWithString: "No preview available.")
    private let fallbackContent = NSStackView()
    private var quickLookView: QLPreviewView?

    init(url: URL, allowsQuickLook: Bool, reason: Reason) {
        fileURL = url
        self.allowsQuickLook = allowsQuickLook
        super.init(frame: .zero)
        buildInterface(reason: reason)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func activate() {
        guard allowsQuickLook else { return }
        if quickLookView != nil { return }

        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.autostarts = false
        preview.previewItem = FilePreviewItem(url: fileURL)
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        quickLookView = preview
        fallbackContent.isHidden = true
    }

    func deactivate() {
        quickLookView?.close()
        quickLookView?.removeFromSuperview()
        quickLookView = nil
        fallbackContent.isHidden = false
    }

    func close() {
        deactivate()
    }

    static func supportsQuickLook(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              !blockedExtensions.contains(fileExtension),
              let type = UTType(filenameExtension: fileExtension)
        else { return false }

        return type.conforms(to: .pdf)
            || type.conforms(to: .audio)
            || type.conforms(to: .movie)
            || officeExtensions.contains(fileExtension)
    }

    static func shouldOpenWithoutTextDecoding(url: URL) -> Bool {
        blockedExtensions.contains(url.pathExtension.lowercased())
    }

    private func buildInterface(reason: Reason) {
        wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSWorkspace.shared.icon(forFile: fileURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityLabel("File icon")

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = fileURL.lastPathComponent
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.toolTip = fileURL.path

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.maximumNumberOfLines = 2

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        if !allowsQuickLook {
            switch reason {
            case .binary:
                detailLabel.stringValue = "No preview available."
            case .unsupportedEncoding:
                detailLabel.stringValue = "This file uses an unsupported text encoding."
            case .tooLarge:
                detailLabel.stringValue = "This file is larger than 5 MiB."
            }
        } else {
            detailLabel.stringValue = "No preview available."
        }
        detailLabel.setAccessibilityLabel("File preview status")

        fallbackContent.setViews([iconView, nameLabel, messageLabel, detailLabel], in: .leading)
        fallbackContent.translatesAutoresizingMaskIntoConstraints = false
        fallbackContent.orientation = .vertical
        fallbackContent.alignment = .centerX
        fallbackContent.spacing = 8
        addSubview(fallbackContent)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
            fallbackContent.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            fallbackContent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            fallbackContent.centerXAnchor.constraint(equalTo: centerXAnchor),
            fallbackContent.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        ])
    }
}

private final class FilePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        previewItemURL = url
    }
}
