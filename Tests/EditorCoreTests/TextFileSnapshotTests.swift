import Foundation
import XCTest
@testable import EditorCore

final class TextFileSnapshotTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func file(_ name: String, bytes: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testSaveRejectsExternalChangesAndLeavesThemIntact() throws {
        let url = try file("notes.txt", bytes: Data("first".utf8))
        let snapshot = try TextFileSnapshot.read(from: url)
        let externalBytes = Data("external edit".utf8)
        try externalBytes.write(to: url)

        XCTAssertThrowsError(try snapshot.save(text: "my edit")) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
    }

    func testSaveRejectsADeletedFile() throws {
        let url = try file("gone.txt", bytes: Data("opened".utf8))
        let snapshot = try TextFileSnapshot.read(from: url)
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try snapshot.save(text: "edited")) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .changedOnDisk)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveRejectsCanonicalPathRetargetedToASymlink() throws {
        let opened = try file("opened.txt", bytes: Data("same bytes".utf8))
        let replacement = try file("replacement.txt", bytes: Data("same bytes".utf8))
        let snapshot = try TextFileSnapshot.read(from: opened)
        try FileManager.default.removeItem(at: opened)
        try FileManager.default.createSymbolicLink(at: opened, withDestinationURL: replacement)

        XCTAssertThrowsError(try snapshot.save(text: "edited")) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: replacement), Data("same bytes".utf8))
    }

    func testRejectsBinaryControlsAndInvalidUTF8Files() throws {
        let binary = try file("binary.dat", bytes: Data([0x61, 0x00, 0x62]))
        let controlBytes = try file("control.dat", bytes: Data([0x61, 0x1B, 0x62]))
        let invalidUTF8 = try file("invalid.txt", bytes: Data([0xC3, 0x28]))

        XCTAssertThrowsError(try TextFileSnapshot.read(from: binary)) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .binaryFile)
        }
        XCTAssertThrowsError(try TextFileSnapshot.read(from: controlBytes)) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .binaryFile)
        }
        XCTAssertThrowsError(try TextFileSnapshot.read(from: invalidUTF8)) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .unsupportedEncoding)
        }
    }

    func testRejectsFilesAboveTheStorageLimit() throws {
        let oversized = try file("large.txt", bytes: Data(repeating: 0x61, count: TextFileSnapshot.maximumFileSize + 1))

        XCTAssertThrowsError(try TextFileSnapshot.read(from: oversized)) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .fileTooLarge)
        }
    }

    func testBOMAndUniformCRLFArePreservedWhenSaving() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8)
        let url = try file("windows.txt", bytes: original)
        let snapshot = try TextFileSnapshot.read(from: url)

        XCTAssertEqual(snapshot.text, "one\r\ntwo\r\n")
        let saved = try snapshot.save(text: "one\ntwo\nthree\n")
        XCTAssertEqual(saved.text, "one\r\ntwo\r\nthree\r\n")
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    func testUnmodifiedSaveDoesNotRewriteBytes() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("keep\r\nexactly".utf8)
        let url = try file("unchanged.txt", bytes: original)
        let snapshot = try TextFileSnapshot.read(from: url)

        _ = try snapshot.save(text: snapshot.text)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCanonicalEquivalentUnicodeEditWritesItsDistinctUTF8Bytes() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        let url = try file("unicode.txt", bytes: Data(composed.utf8))
        let snapshot = try TextFileSnapshot.read(from: url)

        _ = try snapshot.save(text: decomposed)

        XCTAssertEqual(try Data(contentsOf: url), Data(decomposed.utf8))
    }

    func testOversizedSaveKeepsTheExistingFileUntouched() throws {
        let original = Data("small original".utf8)
        let url = try file("limited.txt", bytes: original)
        let snapshot = try TextFileSnapshot.read(from: url)

        XCTAssertThrowsError(try snapshot.save(text: String(repeating: "x", count: TextFileSnapshot.maximumFileSize + 1))) { error in
            XCTAssertEqual(error as? TextFileSnapshotError, .fileTooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSaveRetainsExecutablePermission() throws {
        let url = try file("script.sh", bytes: Data("#!/bin/sh\necho old\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let snapshot = try TextFileSnapshot.read(from: url)

        _ = try snapshot.save(text: "#!/bin/sh\necho new\n")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
}
