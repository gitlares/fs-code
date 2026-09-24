import Foundation
import XCTest
@testable import FSCode

final class ChatAttachmentsTests: XCTestCase {
    func testProjectReferencesAndExternalSnapshotsPersistSeparatelyFromComposerMetadata() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let external = project.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: external) }
        try "outside data".write(to: external, atomically: true, encoding: .utf8)
        let chatID = UUID()
        let store = try ChatAttachmentStore(projectURL: project)
        _ = try store.addProjectReference(chatID: chatID, relativePath: "Sources/App.swift")
        _ = try store.addExternalFile(chatID: chatID, url: external)

        let visible = store.attachments(chatID: chatID)
        XCTAssertEqual(visible.count, 2)
        XCTAssertFalse(visible.contains(where: { $0.sourcePath.contains("outside data") }))
        let payload = try store.renderedPayload(chatID: chatID)
        XCTAssertTrue(payload.contains("fs_read_file"))
        XCTAssertTrue(payload.contains("outside data"))

        let reloaded = try ChatAttachmentStore(projectURL: project)
        XCTAssertEqual(try reloaded.load(chatID: chatID), visible)
        let sidecar = project.appendingPathComponent(".fscode/chat-attachments/\(chatID.uuidString).json")
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testExternalFilesAreBoundedAndAttachmentLimitIsEnforced() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let oversized = project.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: oversized) }
        try Data(repeating: 65, count: ChatAttachmentStore.maximumExternalBytes + 1).write(to: oversized)
        let store = try ChatAttachmentStore(projectURL: project)
        XCTAssertThrowsError(try store.addExternalFile(chatID: UUID(), url: oversized)) { error in
            XCTAssertEqual(error as? ChatAttachmentError, .fileTooLarge)
        }

        let chatID = UUID()
        for index in 0..<ChatAttachmentStore.maximumAttachments {
            _ = try store.addProjectReference(chatID: chatID, relativePath: "Sources/File\(index).swift")
        }
        XCTAssertThrowsError(try store.addProjectReference(chatID: chatID, relativePath: "Sources/Extra.swift")) { error in
            XCTAssertEqual(error as? ChatAttachmentError, .limitReached)
        }
    }

    func testClearRemovesOnlyTheChatSidecar() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let chatID = UUID()
        let store = try ChatAttachmentStore(projectURL: project)
        XCTAssertEqual(try store.renderedPayload(chatID: chatID), "")
        _ = try store.addProjectReference(chatID: chatID, relativePath: "Sources/App.swift")
        try store.clear(chatID: chatID)
        XCTAssertTrue(store.attachments(chatID: chatID).isEmpty)
        XCTAssertEqual(try store.renderedPayload(chatID: chatID), "")
        XCTAssertTrue(try ChatAttachmentStore(projectURL: project).load(chatID: chatID).isEmpty)
    }

    func testMetadataSymlinkIsRejectedForLoadAndClear() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let outside = project.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".fscode"), withDestinationURL: outside)
        let store = try ChatAttachmentStore(projectURL: project)
        XCTAssertThrowsError(try store.load(chatID: UUID()))
        XCTAssertThrowsError(try store.clear(chatID: UUID()))
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }
}
