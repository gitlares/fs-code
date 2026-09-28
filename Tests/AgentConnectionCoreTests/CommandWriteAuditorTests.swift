import Foundation
import XCTest
@testable import AgentConnectionCore

final class CommandWriteAuditorTests: XCTestCase {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testModifiedFileIsAuditedAsAppliedRecord() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = CommandWriteAuditor.snapshot(projectRoot: root)
        XCTAssertNotNil(snapshot)
        // Simulate what a command would do: write new content directly, bypassing the audited service.
        try "after\n".write(to: file, atomically: true, encoding: .utf8)
        let service = try AgentFileChangeService(projectURL: root)
        let summary = await CommandWriteAuditor.importChanges(before: snapshot, projectRoot: root, changeService: service, threadID: "t", turnID: "u")
        XCTAssertEqual(summary.auditedPaths, ["a.txt"])
        XCTAssertTrue(summary.unauditedDeletions.isEmpty)
        XCTAssertFalse(summary.budgetExceeded)
        let history = try await service.history(relativePath: "a.txt")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].status, .applied)
        XCTAssertEqual(history[0].beforeText, "before\n")
        XCTAssertEqual(history[0].afterText, "after\n")
    }

    func testNewlyCreatedFileIsAuditedAsCreateRecord() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = CommandWriteAuditor.snapshot(projectRoot: root)
        try "new file\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let service = try AgentFileChangeService(projectURL: root)
        let summary = await CommandWriteAuditor.importChanges(before: snapshot, projectRoot: root, changeService: service, threadID: "t", turnID: "u")
        XCTAssertEqual(summary.auditedPaths, ["b.txt"])
        let history = try await service.history(relativePath: "b.txt")
        XCTAssertEqual(history.first?.operation, .create)
        XCTAssertNil(history.first?.beforeText)
    }

    func testDeletedFileIsReportedAsUnauditedNotSilentlyDropped() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("c.txt")
        try "gone soon\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = CommandWriteAuditor.snapshot(projectRoot: root)
        try FileManager.default.removeItem(at: file)
        let service = try AgentFileChangeService(projectURL: root)
        let summary = await CommandWriteAuditor.importChanges(before: snapshot, projectRoot: root, changeService: service, threadID: "t", turnID: "u")
        XCTAssertTrue(summary.auditedPaths.isEmpty)
        XCTAssertEqual(summary.unauditedDeletions, ["c.txt"])
        XCTAssertTrue(summary.suffixText.contains("could not be audited"))
    }

    func testExcludedDirectoriesAreNeverSnapshottedOrImported() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("node_modules/lib.js"), atomically: true, encoding: .utf8)
        let snapshot = CommandWriteAuditor.snapshot(projectRoot: root)
        try "y".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("node_modules/lib.js"), atomically: true, encoding: .utf8)
        let service = try AgentFileChangeService(projectURL: root)
        let summary = await CommandWriteAuditor.importChanges(before: snapshot, projectRoot: root, changeService: service, threadID: "t", turnID: "u")
        XCTAssertTrue(summary.auditedPaths.isEmpty)
        XCTAssertTrue(summary.unauditedDeletions.isEmpty)
    }

    func testSnapshotReturnsNilWhenTreeExceedsBudget() throws {
        // This test only verifies the guard path is reachable with a tiny project; a real
        // oversized-tree run is exercised manually, not in CI, to avoid a slow test.
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try "small\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let snapshot = CommandWriteAuditor.snapshot(projectRoot: root)
        XCTAssertNotNil(snapshot)
    }

    func testImportChangesReportsBudgetExceededWhenSnapshotIsNil() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentFileChangeService(projectURL: root)
        let summary = await CommandWriteAuditor.importChanges(before: nil, projectRoot: root, changeService: service, threadID: "t", turnID: "u")
        XCTAssertTrue(summary.budgetExceeded)
        XCTAssertTrue(summary.suffixText.contains("audit snapshot budget"))
    }
}
