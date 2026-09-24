import Foundation
import XCTest
@testable import AgentConnectionCore

final class ProjectPlanStoreTests: XCTestCase {
    func testForgedMetadataDoesNotApprovePlan() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        let plan = try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body(), expectedRevision: nil)
        var forged = plan.markdown.replacingOccurrences(of: "status: draft", with: "status: approved")
        forged = forged.replacingOccurrences(of: "approved_via: none", with: "approved_via: editor-action")
        try forged.write(to: fixture.planURL("one"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try fixture.store.isApproved(planID: "one"))
    }

    func testApprovalWritesHostStatusAndTwoPlansCoexist() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        _ = try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body(), expectedRevision: nil)
        _ = try fixture.store.saveDraft(planID: "two", title: "Two", format: .short, body: body(), expectedRevision: nil)
        _ = try fixture.store.approve(planID: "one")
        _ = try fixture.store.approve(planID: "two")
        let one = try fixture.store.read(planID: "one")
        XCTAssertEqual(one.metadata.status, .approved)
        XCTAssertTrue(one.markdown.contains("approved_via: editor-action"))
        XCTAssertTrue(try fixture.store.isApproved(planID: "one"))
        XCTAssertTrue(try fixture.store.isApproved(planID: "two"))
    }

    func testEditInvalidatesApprovalAndOldHashIsStale() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        let first = try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body(), expectedRevision: nil)
        _ = try fixture.store.approve(planID: "one")
        let approved = try fixture.store.read(planID: "one")
        let edited = try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body("changed"), expectedRevision: approved.metadata.revision, expectedContentHash: approved.metadata.contentHash)
        XCTAssertTrue(edited.markdown.contains("base_commit: unknown"))
        XCTAssertFalse(try fixture.store.isApproved(planID: "one"))
        XCTAssertThrowsError(try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body(), expectedRevision: 2, expectedContentHash: first.metadata.contentHash))
    }

    func testExecutionAllowsStatusButRejectsCriterionAndObjectiveMutation() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        _ = try fixture.store.saveDraft(planID: "one", title: "One", format: .short, body: body(), expectedRevision: nil)
        _ = try fixture.store.approve(planID: "one")
        let approved = try fixture.store.read(planID: "one")
        _ = try fixture.store.updateExecution(planID: "one", expectedRevision: approved.metadata.revision) { $0 = $0.replacingOccurrences(of: "status: approved", with: "status: in_progress") }
        XCTAssertTrue(try fixture.store.isApproved(planID: "one"))
        let current = try fixture.store.read(planID: "one")
        XCTAssertThrowsError(try fixture.store.updateExecution(planID: "one", expectedRevision: current.metadata.revision) { $0 = $0.replacingOccurrences(of: "G1 observable", with: "G1 changed") })
        XCTAssertThrowsError(try fixture.store.updateExecution(planID: "one", expectedRevision: current.metadata.revision) { $0 = $0.replacingOccurrences(of: "Objective", with: "Objective altered") })
    }

    func testMalformedMetadataAndSymlinkParentAreRejected() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".fs/plans"), withIntermediateDirectories: true)
        try "---\nplan_id: one\nplan_id: one\ntitle: One\nformat: short\nstatus: draft\nrevision: 1\n---\n".write(to: fixture.planURL("one"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.read(planID: "one"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".fs"))
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".fs"), withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.store.saveDraft(planID: "two", title: "Two", format: .short, body: body(), expectedRevision: nil))
    }

    func testImportDraftPreservesMetadataAndRejectsInProgressOverwrite() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        let markdown = "---\nplan_id: imported\ntitle: Imported\nformat: short\nstatus: draft\napproved_via: none\nrevision: 1\ncreated: 2026-09-24\nbase_commit: abc\n---\n\n# Imported\n\n" + body()
        let imported = try fixture.store.importDraft(planID: "imported", markdown: markdown)
        XCTAssertEqual(imported.metadata.revision, 1)
        _ = try fixture.store.approve(planID: "imported")
        let approved = try fixture.store.read(planID: "imported")
        _ = try fixture.store.updateExecution(planID: "imported", expectedRevision: approved.metadata.revision) { $0 = $0.replacingOccurrences(of: "status: approved", with: "status: in_progress") }
        XCTAssertThrowsError(try fixture.store.importDraft(planID: "imported", markdown: markdown))
    }

    func testImportDraftRequiresExactRevisionIncrement() throws {
        let fixture = try makeStore()
        defer { fixture.remove() }
        let initial = "---\nplan_id: imported\ntitle: Imported\nformat: short\nstatus: draft\napproved_via: none\nrevision: 1\ncreated: 2026-09-24\nbase_commit: abc\n---\n\n# Imported\n\n" + body()
        _ = try fixture.store.importDraft(planID: "imported", markdown: initial)
        XCTAssertThrowsError(try fixture.store.importDraft(planID: "imported", markdown: initial))
        let next = initial.replacingOccurrences(of: "revision: 1", with: "revision: 2")
        XCTAssertEqual(try fixture.store.importDraft(planID: "imported", markdown: next).metadata.revision, 2)
    }

    private func body(_ suffix: String = "") -> String {
        "## Objective\nKeep behavior \(suffix)\n\n## Steps\n\n### S1 — Do work\n- Status: pending\n\n## Global acceptance criteria\n- [ ] G1 observable"
    }

    private func makeStore() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, support: support, store: try ProjectPlanStore(projectURL: root, applicationSupportURL: support))
    }
}

private struct Fixture {
    let root: URL
    let support: URL
    let store: ProjectPlanStore
    func planURL(_ id: String) -> URL { root.appendingPathComponent(".fs/plans/\(id).md") }
    func remove() { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: support) }
}
