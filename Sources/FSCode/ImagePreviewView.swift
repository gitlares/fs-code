import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A lightweight, native preview for image editor tabs.
///
/// Raster data is read and decoded off the main thread.  Its input and rendered
/// dimensions are deliberately bounded so selecting an image cannot unexpectedly
/// consume the editor's memory budget.
@MainActor
final class ImagePreviewView: NSView {
    private static let maximumInputBytes = 25 * 1024 * 1024
    private static let maximumSVGBytes = 5 * 1024 * 1024
    private static let thumbnailMaximumPixelSize = 2_048
    private static let rasterExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "icns", "ico", "jp2", "jpeg", "jpg",
        "j2k", "png", "tif", "tiff", "webp"
    ]
    private static let maximumSVGDimension: CGFloat = 100_000

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "No image selected")
    private let statusIcon = NSImageView()
    private let statusRow = NSStackView()
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setAccessibilityLabel("Image preview")
        addSubview(imageView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setAccessibilityLabel("Image preview status")
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.isHidden = true
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 5
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(statusIcon)
        statusRow.addArrangedSubview(statusLabel)
        addSubview(statusRow)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            imageView.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -12),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            statusRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func updateLayer() {
        // A semantic colour keeps transparent pixels legible in either appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    deinit {
        loadTask?.cancel()
    }

    static func supportsRaster(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard rasterExtensions.contains(fileExtension),
              let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .image),
              !type.conforms(to: .svg),
              !type.conforms(to: .pdf) else {
            return false
        }
        return true
    }

    /// Starts a new bounded raster load. A later request always wins over an older one.
    func loadRaster(from url: URL) {
        beginLoading(status: "Loading image…")
        let requestGeneration = generation
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let maximumInputBytes = Self.maximumInputBytes
        let maximumPixelSize = Self.thumbnailMaximumPixelSize

        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                RasterDecoder.decode(url: resolvedURL,
                                     maximumInputBytes: maximumInputBytes,
                                     maximumPixelSize: maximumPixelSize)
            }
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })

            guard !Task.isCancelled, let self, requestGeneration == self.generation else { return }
            switch result {
            case let .success(image):
                self.imageView.image = NSImage(cgImage: image.cgImage, size: image.displaySize)
                self.setStatus("\(image.format) • \(image.width) × \(image.height)", isError: false)
            case let .failure(message):
                self.setStatus(message, isError: true)
            }
        }
    }

    /// Validates and renders editor-supplied SVG source with AppKit's native decoder.
    func showSVG(source: String) {
        beginLoading(status: "Loading SVG…")

        let byteCount = source.lengthOfBytes(using: .utf8)
        guard byteCount <= Self.maximumSVGBytes else {
            setStatus("SVG is larger than 5 MiB", isError: true)
            return
        }
        guard let data = source.data(using: .utf8) else {
            setStatus("SVG could not be encoded as UTF-8", isError: true)
            return
        }
        guard SVGValidator.validate(data: data) else {
            setStatus("SVG is invalid or uses unsupported external content", isError: true)
            return
        }
        guard let image = NSImage(data: data), image.isValid else {
            setStatus("This SVG cannot be rendered natively", isError: true)
            return
        }

        let size = image.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= Self.maximumSVGDimension, size.height <= Self.maximumSVGDimension else {
            setStatus("SVG has unsupported dimensions", isError: true)
            return
        }
        imageView.image = image
        setStatus("SVG • \(Int(size.width.rounded())) × \(Int(size.height.rounded()))", isError: false)
    }

    private func beginLoading(status: String) {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        // Never retain a previous successful image while a new request is pending or failed.
        imageView.image = nil
        setStatus(status, isError: false)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .labelColor : .secondaryLabelColor
        statusIcon.image = isError
            ? NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Image preview error")
            : nil
        statusIcon.contentTintColor = .systemRed
        statusIcon.isHidden = !isError
        statusLabel.setAccessibilityValue(text)
    }
}

private enum RasterDecoder {
    enum DecodeResult: Sendable {
        case success(DecodedImage)
        case failure(String)
    }

    struct DecodedImage: @unchecked Sendable {
        let cgImage: CGImage
        let displaySize: NSSize
        let width: Int
        let height: Int
        let format: String
    }

    static func decode(url: URL, maximumInputBytes: Int, maximumPixelSize: Int) -> DecodeResult {
        do {
            guard !Task.isCancelled else { return .failure("Image loading was cancelled") }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize else {
                return .failure("Image is not a regular file")
            }
            guard fileSize <= maximumInputBytes else {
                return .failure("Image is larger than 25 MiB")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maximumInputBytes + 1) else {
                return .failure("Image could not be read")
            }
            guard data.count <= maximumInputBytes else {
                return .failure("Image is larger than 25 MiB")
            }
            guard !Task.isCancelled else { return .failure("Image loading was cancelled") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary) else {
                return .failure("This image could not be decoded")
            }
            guard !Task.isCancelled else { return .failure("Image loading was cancelled") }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? thumbnail.width
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? thumbnail.height
            let typeIdentifier = CGImageSourceGetType(source).map { $0 as String }
            let extensionName = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }
            let format = extensionName?.uppercased() ?? url.pathExtension.uppercased()
            return .success(DecodedImage(cgImage: thumbnail,
                                         displaySize: NSSize(width: thumbnail.width, height: thumbnail.height),
                                         width: width,
                                         height: height,
                                         format: format))
        } catch {
            return .failure("Image could not be read")
        }
    }
}

private final class SVGValidator: NSObject, XMLParserDelegate {
    private static let rasterDataFormats: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]
    private static let presentationAttributes: Set<String> = [
        "clip-path", "color", "fill", "filter", "flood-color", "lighting-color", "marker",
        "marker-end", "marker-mid", "marker-start", "mask", "stop-color", "stroke"
    ]
    private var rejected = false
    private var styleDepth = 0
    private var styleText = ""

    static func validate(data: Data) -> Bool {
        let validator = SVGValidator()
        let parser = XMLParser(data: data)
        parser.delegate = validator
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !validator.rejected && !validator.containsExternalStyleReference(validator.styleText)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        reject(parser)
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        reject(parser)
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        if target.caseInsensitiveCompare("xml-stylesheet") == .orderedSame {
            reject(parser)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        if element == "script" || element == "foreignobject" {
            reject(parser)
            return
        }
        if element == "style" { styleDepth += 1 }

        for (name, value) in attributeDict {
            let attribute = name.lowercased()
            if attribute == "xml:base" {
                reject(parser)
                return
            }
            if attribute == "href" || attribute.hasSuffix(":href") {
                let reference = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !reference.hasPrefix("#") && !isSafeDataRasterReference(reference) {
                    reject(parser)
                    return
                }
            }
            let hasEscapedOrCommentedCSS = value.contains("\\") || value.contains("/*")
            if (attribute == "style" ||
                value.localizedCaseInsensitiveContains("url(") ||
                (Self.presentationAttributes.contains(attribute) && hasEscapedOrCommentedCSS)) &&
                containsExternalStyleReference(value) {
                reject(parser)
                return
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 {
            styleText += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard styleDepth > 0 else { return }
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            reject(parser)
            return
        }
        styleText += text
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.caseInsensitiveCompare("style") == .orderedSame {
            styleDepth = max(0, styleDepth - 1)
        }
    }

    private func containsExternalStyleReference(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        // CSS escapes and comments can conceal a URL; this preview supports only
        // the simple inline subset that can be checked without a CSS engine.
        guard !lowercased.contains("@import"),
              !lowercased.contains("/*"),
              !lowercased.contains("\\") else { return true }
        let pattern = #"url\(\s*['"]?\s*([^'")\s]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return true }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).contains { match in
            guard let referenceRange = Range(match.range(at: 1), in: value) else { return true }
            let reference = value[referenceRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !reference.hasPrefix("#")
        }
    }

    private func isSafeDataRasterReference(_ reference: String) -> Bool {
        guard reference.hasPrefix("data:image/") else { return false }
        let mediaType = reference
            .dropFirst("data:image/".count)
            .prefix { $0 != ";" && $0 != "," }
        return Self.rasterDataFormats.contains(String(mediaType))
    }

    private func reject(_ parser: XMLParser) {
        rejected = true
        parser.abortParsing()
    }
}
