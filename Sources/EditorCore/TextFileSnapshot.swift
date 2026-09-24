import Foundation

public enum TextFileSnapshotError: Error, LocalizedError, Equatable, Sendable {
    case notRegularFile
    case fileTooLarge
    case unsupportedEncoding
    case binaryFile
    case changedOnDisk
    case couldNotRead
    case couldNotWrite

    public var errorDescription: String? {
        switch self {
        case .notRegularFile: "Only regular files can be opened in the editor."
        case .fileTooLarge: "This file is larger than 5 MiB and cannot be opened in the editor."
        case .unsupportedEncoding: "This file is not valid UTF-8 and cannot be opened in the editor."
        case .binaryFile: "Binary files cannot be opened in the editor."
        case .changedOnDisk: "This file changed or was removed on disk. Review the current file before saving."
        case .couldNotRead: "The file could not be read."
        case .couldNotWrite: "The file could not be saved."
        }
    }
}

/// An immutable view of a UTF-8 text file. Saving detects bytes changed before its atomic replacement; it is not a multiwriter transaction.
public struct TextFileSnapshot: Sendable {
    public static let maximumFileSize = 5 * 1024 * 1024

    public let url: URL
    public let text: String
    private let originalBytes: Data
    private let hasUTF8BOM: Bool
    private let usesUniformCRLF: Bool

    private init(url: URL, text: String, originalBytes: Data, hasUTF8BOM: Bool, usesUniformCRLF: Bool) {
        self.url = url
        self.text = text
        self.originalBytes = originalBytes
        self.hasUTF8BOM = hasUTF8BOM
        self.usesUniformCRLF = usesUniformCRLF
    }

    public static func read(from url: URL) throws -> Self {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let bytes = try readRegularFile(at: canonicalURL)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = bytes.starts(with: bom)
        let textBytes = hasBOM ? Data(bytes.dropFirst(bom.count)) : bytes

        guard !containsBinaryControls(textBytes) else { throw TextFileSnapshotError.binaryFile }
        guard let text = String(data: textBytes, encoding: .utf8) else { throw TextFileSnapshotError.unsupportedEncoding }

        return Self(
            url: canonicalURL,
            text: text,
            originalBytes: bytes,
            hasUTF8BOM: hasBOM,
            usesUniformCRLF: hasOnlyCRLFLineEndings(text)
        )
    }

    /// Writes atomically only when the file still contains the exact bytes that were opened.
    public func save(text: String) throws -> Self {
        let currentURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard currentURL == url, let currentBytes = try? Self.readRegularFile(at: url), currentBytes == originalBytes else {
            throw TextFileSnapshotError.changedOnDisk
        }
        guard currentBytes.count <= Self.maximumFileSize else { throw TextFileSnapshotError.changedOnDisk }

        guard !text.utf8.elementsEqual(self.text.utf8) else { return self }
        let normalizedText = usesUniformCRLF ? Self.withCRLFLineEndings(text) : text
        guard let textBytes = normalizedText.data(using: .utf8) else { throw TextFileSnapshotError.couldNotWrite }
        var savedBytes = Data()
        if hasUTF8BOM { savedBytes.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        savedBytes.append(textBytes)
        guard savedBytes.count <= Self.maximumFileSize else { throw TextFileSnapshotError.fileTooLarge }

        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        do {
            try savedBytes.write(to: url, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } catch {
            throw TextFileSnapshotError.couldNotWrite
        }
        return Self(
            url: url,
            text: normalizedText,
            originalBytes: savedBytes,
            hasUTF8BOM: hasUTF8BOM,
            usesUniformCRLF: usesUniformCRLF
        )
    }

    private static func readRegularFile(at url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw TextFileSnapshotError.notRegularFile }
            guard (values.fileSize ?? 0) <= maximumFileSize else { throw TextFileSnapshotError.fileTooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            guard bytes.count <= maximumFileSize else { throw TextFileSnapshotError.fileTooLarge }
            return bytes
        } catch let error as TextFileSnapshotError {
            throw error
        } catch {
            throw TextFileSnapshotError.couldNotRead
        }
    }

    private static func hasOnlyCRLFLineEndings(_ text: String) -> Bool {
        var previousWasCR = false
        var foundCRLF = false
        for byte in text.utf8 {
            if byte == 0x0A {
                guard previousWasCR else { return false }
                foundCRLF = true
            } else if previousWasCR {
                return false
            }
            previousWasCR = byte == 0x0D
        }
        return foundCRLF && !previousWasCR
    }

    private static func containsBinaryControls(_ bytes: Data) -> Bool {
        bytes.contains { byte in
            (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) || byte == 0x7F
        }
    }

    private static func withCRLFLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }
}
