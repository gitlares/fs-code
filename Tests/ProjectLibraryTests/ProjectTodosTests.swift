import Foundation
import XCTest
@testable import ProjectLibrary

final class ProjectTodosTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func project(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProjectsAreIsolatedAndReopenPersistsJSON() throws {
        let firstURL = try project("first")
        let secondURL = try project("second")
        let first = try ProjectTodos(projectURL: firstURL)
        let second = try ProjectTodos(projectURL: secondURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.storageURL.path))

        let created = ProjectTodo(title: "  Ship  ", description: "Release notes")
        try first.save(created)

        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items[0].title, "Ship")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.storageURL.path))
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(try ProjectTodos(projectURL: firstURL).items[0].id, created.id)
        let text = try String(contentsOf: first.storageURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertTrue(text.contains("T"))
    }

    func testUpdateCommentsStatusAndDelete() throws {
        let projectURL = try project("work")
        let store = try ProjectTodos(projectURL: projectURL)
        let createdAt = Date(timeIntervalSince1970: 100)
        let original = ProjectTodo(title: "Review", createdAt: createdAt, updatedAt: createdAt)
        try store.save(original)
        let persisted = store.items[0]
        var updated = persisted
        updated.isCompleted = true
        updated.comments = [TodoComment(text: "  Approved  ")]
        try store.save(updated)

        XCTAssertTrue(store.items[0].isCompleted)
        XCTAssertEqual(store.items[0].comments.map(\.text), ["Approved"])
        XCTAssertEqual(store.items[0].createdAt, createdAt)
        XCTAssertGreaterThanOrEqual(store.items[0].updatedAt, persisted.updatedAt)
        try store.remove(original.id)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue((try ProjectTodos(projectURL: projectURL)).items.isEmpty)
    }

    func testInvalidAndUnknownVersionFilesArePreserved() throws {
        let invalidProject = try project("invalid")
        let invalidURL = invalidProject.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: invalidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{ bad json".utf8)
        try invalid.write(to: invalidURL)
        XCTAssertThrowsError(try ProjectTodos(projectURL: invalidProject)) { XCTAssertEqual($0 as? ProjectTodosError, .invalidStorage) }
        XCTAssertEqual(try Data(contentsOf: invalidURL), invalid)

        let futureProject = try project("future")
        let futureURL = futureProject.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: futureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"version":2,"items":[]}"#.utf8)
        try future.write(to: futureURL)
        XCTAssertThrowsError(try ProjectTodos(projectURL: futureProject)) { XCTAssertEqual($0 as? ProjectTodosError, .unsupportedVersion) }
        XCTAssertEqual(try Data(contentsOf: futureURL), future)
    }

    func testDuplicateIDsInStoredDocumentAreRejected() throws {
        let todoID = UUID()
        let commentID = UUID()
        let duplicateTodoProject = try project("duplicate-todos")
        let duplicateTodoURL = duplicateTodoProject.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: duplicateTodoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let duplicateTodos = Data(#"{"version":1,"items":[{"id":"\#(todoID.uuidString)","title":"One","description":"","comments":[],"isCompleted":false,"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"},{"id":"\#(todoID.uuidString)","title":"Two","description":"","comments":[],"isCompleted":false,"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}]}"#.utf8)
        try duplicateTodos.write(to: duplicateTodoURL)
        XCTAssertThrowsError(try ProjectTodos(projectURL: duplicateTodoProject)) { XCTAssertEqual($0 as? ProjectTodosError, .duplicateTodoID) }
        XCTAssertEqual(try Data(contentsOf: duplicateTodoURL), duplicateTodos)

        let duplicateCommentProject = try project("duplicate-comments")
        let duplicateCommentURL = duplicateCommentProject.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: duplicateCommentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let duplicateComments = Data(#"{"version":1,"items":[{"id":"\#(UUID().uuidString)","title":"One","description":"","comments":[{"id":"\#(commentID.uuidString)","text":"First","createdAt":"2020-01-01T00:00:00Z"},{"id":"\#(commentID.uuidString)","text":"Second","createdAt":"2020-01-01T00:00:00Z"}],"isCompleted":false,"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}]}"#.utf8)
        try duplicateComments.write(to: duplicateCommentURL)
        XCTAssertThrowsError(try ProjectTodos(projectURL: duplicateCommentProject)) { XCTAssertEqual($0 as? ProjectTodosError, .duplicateCommentID) }
        XCTAssertEqual(try Data(contentsOf: duplicateCommentURL), duplicateComments)
    }

    func testExternalChangeConflictsAndValidationDoesNotWrite() throws {
        let url = try project("conflict")
        let store = try ProjectTodos(projectURL: url)
        XCTAssertThrowsError(try store.save(ProjectTodo(title: " \n "))) { XCTAssertEqual($0 as? ProjectTodosError, .emptyTitle) }
        XCTAssertThrowsError(try store.save(ProjectTodo(title: "Valid", comments: [TodoComment(text: " ")]))) { XCTAssertEqual($0 as? ProjectTodosError, .emptyComment) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))

        try store.save(ProjectTodo(title: "First"))
        let before = store.items
        let external = Data(#"{"version":1,"items":[]}"#.utf8)
        try external.write(to: store.storageURL)
        XCTAssertThrowsError(try store.save(ProjectTodo(title: "Second"))) { XCTAssertEqual($0 as? ProjectTodosError, .externalChangeConflict) }
        XCTAssertEqual(store.items, before)
        XCTAssertEqual(try Data(contentsOf: store.storageURL), external)
    }

    func testFailedWriteAndFailedReloadPreserveInMemoryItems() throws {
        let blockedProject = try project("blocked")
        let metadataDirectory = blockedProject.appendingPathComponent(".fscode")
        let originalMetadata = Data("not a directory".utf8)
        try originalMetadata.write(to: metadataDirectory)
        let blockedStore = try ProjectTodos(projectURL: blockedProject)
        XCTAssertThrowsError(try blockedStore.save(ProjectTodo(title: "Cannot persist")))
        XCTAssertTrue(blockedStore.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: metadataDirectory), originalMetadata)

        let reloadProject = try project("reload")
        let store = try ProjectTodos(projectURL: reloadProject)
        try store.save(ProjectTodo(title: "Saved"))
        let previous = store.items
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: store.storageURL)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? ProjectTodosError, .invalidStorage) }
        XCTAssertEqual(store.items, previous)
        XCTAssertEqual(try Data(contentsOf: store.storageURL), corrupt)
    }

    func testV1DocumentWithoutMetadataDefaultsAndMetadataReopens() throws {
        let projectURL = try project("metadata")
        let storageURL = projectURL.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let legacy = Data(#"{"version":1,"items":[{"id":"\#(id.uuidString)","title":"Legacy","description":"","comments":[],"isCompleted":false,"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}]}"#.utf8)
        try legacy.write(to: storageURL)

        let store = try ProjectTodos(projectURL: projectURL)
        XCTAssertEqual(store.items[0].relevance, .normal)
        XCTAssertNil(store.items[0].linkedFilePath)

        var updated = store.items[0]
        updated.relevance = .high
        updated.linkedFilePath = "Sources/Missing.swift"
        try store.save(updated)
        let reopened = try ProjectTodos(projectURL: projectURL)
        XCTAssertEqual(reopened.items[0].relevance, .high)
        XCTAssertEqual(reopened.items[0].linkedFilePath, "Sources/Missing.swift")
        XCTAssertEqual(try reopened.linkedFileURL(for: reopened.items[0]), projectURL.appendingPathComponent("Sources/Missing.swift"))
    }

    func testLegacyLinkedPathRemainsManualAndIsPreservedWhenSaving() throws {
        let projectURL = try project("legacy-link")
        let storageURL = projectURL.appendingPathComponent(".fscode/todos.json")
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let legacy = Data(#"{"version":1,"items":[{"id":"\#(id.uuidString)","title":"Legacy","description":"","comments":[],"isCompleted":false,"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z","linkedFilePath":"Sources/Legacy.swift"}]}"#.utf8)
        try legacy.write(to: storageURL)

        let store = try ProjectTodos(projectURL: projectURL)
        XCTAssertEqual(store.items[0].origin, .manual)
        XCTAssertNil(store.items[0].sourceLocation)
        XCTAssertNil(try store.inlineSource(for: store.items[0]))

        var updated = store.items[0]
        updated.description = "Updated without editing the legacy link"
        try store.save(updated)
        let reopened = try ProjectTodos(projectURL: projectURL)
        XCTAssertEqual(reopened.items[0].linkedFilePath, "Sources/Legacy.swift")
        XCTAssertEqual(reopened.items[0].origin, .manual)
        XCTAssertNil(reopened.items[0].sourceLocation)
    }

    func testInlineSourceProvenanceRoundTripsWithSourceLine() throws {
        let projectURL = try project("inline-link")
        let sourceURL = projectURL.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// TODO: Check this\n".utf8).write(to: sourceURL)
        let store = try ProjectTodos(projectURL: projectURL)
        let todo = ProjectTodo(
            title: "Check this",
            linkedFilePath: "Sources/App.swift",
            origin: .inlineComment,
            sourceLocation: TodoSourceLocation(line: 1, column: 4)
        )

        try store.save(todo)
        let reopened = try ProjectTodos(projectURL: projectURL)
        let source = try XCTUnwrap(reopened.inlineSource(for: reopened.items[0]))
        XCTAssertEqual(source.url, sourceURL)
        XCTAssertEqual(source.location, TodoSourceLocation(line: 1, column: 4))
    }

    func testLinkedFilePathRejectsRootEscapesIncludingSymlink() throws {
        let projectURL = try project("links")
        let outsideURL = try project("outside")
        let store = try ProjectTodos(projectURL: projectURL)

        for path in ["/tmp/file.swift", "../outside/file.swift"] {
            XCTAssertThrowsError(try store.save(ProjectTodo(title: "Bad", linkedFilePath: path))) {
                XCTAssertEqual($0 as? ProjectTodosError, .invalidLinkedFilePath)
            }
        }

        let symlink = projectURL.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideURL)
        XCTAssertThrowsError(try store.save(ProjectTodo(title: "Escapes", linkedFilePath: "external/file.swift"))) {
            XCTAssertEqual($0 as? ProjectTodosError, .invalidLinkedFilePath)
        }
        try store.save(ProjectTodo(title: "Missing is okay", linkedFilePath: "Sources/Missing.swift"))
    }
}
