import Foundation
import XCTest
@testable import FSCode

@MainActor
final class FileTreeTests: XCTestCase {
    func testFileTreeIncludesHiddenFilesAndDirectories() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent(".env"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("visible.txt"))

        let names = FileNode(folder).loadChildren().map { $0.url.lastPathComponent }

        XCTAssertEqual(names, [".git", ".env", "visible.txt"])
    }
}
