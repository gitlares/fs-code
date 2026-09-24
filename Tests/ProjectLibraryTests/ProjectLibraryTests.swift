import Foundation
import XCTest
@testable import ProjectLibrary

final class ProjectLibraryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func folder(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLibrary() throws -> ProjectLibrary {
        try ProjectLibrary(storageURL: temporaryDirectory.appendingPathComponent("index/projects.json"))
    }

    func testCustomNamePersistsWithoutRenamingFolderAndPreservesProjectSettings() throws {
        let folder = try folder("actual-folder")
        let config = folder.appendingPathComponent(".fscode/project.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":1,"name":"Old name","settings":{"theme":"night"},"futureValue":42}"#.data(using: .utf8)!.write(to: config)
        let library = try makeLibrary()

        var project = try library.add(folder, named: "Design notes")
        XCTAssertEqual(project.name, "Design notes")
        XCTAssertEqual(folder.lastPathComponent, "actual-folder")
        project.name = "Renamed notes"
        try library.update(project)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        XCTAssertEqual(saved?["name"] as? String, "Renamed notes")
        XCTAssertEqual((saved?["settings"] as? [String: String])?["theme"], "night")
        XCTAssertEqual(saved?["futureValue"] as? Int, 42)
    }

    func testInvalidExistingConfigurationIsNeverOverwritten() throws {
        let folder = try folder("broken")
        let config = folder.appendingPathComponent(".fscode/project.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ not json".utf8)
        try original.write(to: config)
        let library = try makeLibrary()

        XCTAssertThrowsError(try library.add(folder, named: "Should not save")) { error in
            XCTAssertEqual(error as? LibraryError, .invalidProjectConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertTrue(library.projects.isEmpty)
    }

    func testSymlinkToAddedFolderIsRejectedAsDuplicate() throws {
        let folder = try folder("source")
        let alias = temporaryDirectory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let library = try makeLibrary()
        _ = try library.add(folder, named: "Source")

        XCTAssertThrowsError(try library.add(alias, named: "Alias")) { error in
            XCTAssertEqual(error as? LibraryError, .duplicate)
        }
    }

    func testRemoveOnlyRemovesIndexAndLeavesFolderConfigurationUntouched() throws {
        let folder = try folder("keep-me")
        let library = try makeLibrary()
        let project = try library.add(folder, named: "Keep me")
        let config = folder.appendingPathComponent(".fscode/project.json")

        try library.remove(project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(try ProjectLibrary(storageURL: library.storageURL).projects.isEmpty)
    }

    func testSearchOrdersByRecentUseThenDisplayName() throws {
        let library = try makeLibrary()
        var alpha = try library.add(try folder("alpha"), named: "Alpha")
        var beta = try library.add(try folder("beta"), named: "Beta")
        alpha.lastOpened = Date(timeIntervalSinceReferenceDate: 10)
        beta.lastOpened = Date(timeIntervalSinceReferenceDate: 20)
        try library.update(alpha)
        try library.update(beta)

        XCTAssertEqual(library.search("").map(\.name), ["Beta", "Alpha"])
    }
}
