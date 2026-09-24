import XCTest
@testable import AgentContextCore

final class ContextResolverTests: XCTestCase {
    func testStoreCRUDStaleAndCorruptManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContextStore(configuration: .init(projectURL: root, globalStoreURL: root.appendingPathComponent("global")))
        let created = try await store.create(name: "Project", scope: .project, content: "one")
        let updated = try await store.update(id: created.id, expectedHash: created.hash, name: "File", scope: .file, target: "a.swift", priority: 2, enabled: false, content: "two")
        XCTAssertEqual(updated.name, "File")
        XCTAssertFalse(updated.enabled)
        await XCTAssertThrowsErrorAsync { _ = try await store.update(id: created.id, expectedHash: created.hash, content: "three") }
        try Data("broken".utf8).write(to: root.appendingPathComponent(".fs/context/manifest.json"))
        await XCTAssertThrowsErrorAsync { _ = try await store.load() }
    }
    func testStableOrderDuplicateAndUTF8Limit() {
        let global = ContextRule(name: "Global", origin: .fsCode, scope: .global, content: "á", hash: ContextResolver.hash("á"))
        let file = ContextRule(name: "File", origin: .fsCode, scope: .file, target: "a.swift", content: "á", hash: ContextResolver.hash("á"))
        let result = ContextResolver(configuration: .init(maximumUTF8Bytes: 1)).resolve(
            rules: [file, global], projectURL: URL(fileURLWithPath: "/project"), paths: [URL(fileURLWithPath: "/project/a.swift")]
        )
        XCTAssertEqual(result.entries.map(\.state), [.active, .replaced])
        XCTAssertEqual(result.entries.first?.rule.name, "Global")
        XCTAssertEqual(result.utf8ByteCount, result.consolidatedText.lengthOfBytes(using: .utf8))
        XCTAssertFalse(result.canSend)
    }

    func testResolutionOrderCoversStagesDepthPriorityAndDisabledRules() {
        let project = URL(fileURLWithPath: "/project")
        let requested = project.appendingPathComponent("Sources/Nested/App.swift")
        let rules = [
            ContextRule(name: "External", url: project.appendingPathComponent("AGENTS.md"), origin: .external, provider: .codex, scope: .project, enabled: true, content: "external", hash: ContextResolver.hash("external")),
            ContextRule(name: "Exact", origin: .fsCode, scope: .file, target: "Sources/Nested/App.swift", content: "exact", hash: ContextResolver.hash("exact")),
            ContextRule(name: "Glob Late", origin: .fsCode, scope: .glob, target: "Sources/**/*.swift", priority: 20, content: "glob-late", hash: ContextResolver.hash("glob-late")),
            ContextRule(name: "Glob Early", origin: .fsCode, scope: .glob, target: "Sources/**/*.swift", priority: -1, content: "glob-early", hash: ContextResolver.hash("glob-early")),
            ContextRule(name: "Folder Child", origin: .fsCode, scope: .folder, target: "Sources/Nested", priority: -100, content: "folder-child", hash: ContextResolver.hash("folder-child")),
            ContextRule(name: "Folder Parent", origin: .fsCode, scope: .folder, target: "Sources", priority: 100, content: "folder-parent", hash: ContextResolver.hash("folder-parent")),
            ContextRule(name: "Project Late", origin: .fsCode, scope: .project, priority: 10, content: "project-late", hash: ContextResolver.hash("project-late")),
            ContextRule(name: "Project Early", origin: .fsCode, scope: .project, priority: -10, content: "project-early", hash: ContextResolver.hash("project-early")),
            ContextRule(name: "Disabled", origin: .fsCode, scope: .project, enabled: false, priority: -100, content: "disabled", hash: ContextResolver.hash("disabled")),
            ContextRule(name: "Global", origin: .fsCode, scope: .global, content: "global", hash: ContextResolver.hash("global"))
        ]

        let result = ContextResolver().resolve(rules: rules, projectURL: project, paths: [requested])

        XCTAssertEqual(
            result.entries.filter { $0.state == .active }.map(\.rule.name),
            ["Global", "Project Early", "Project Late", "Folder Parent", "Folder Child", "Glob Early", "Glob Late", "Exact", "External"]
        )
        let disabled = result.entries.first { $0.rule.name == "Disabled" }
        XCTAssertEqual(disabled?.state, .ignored)
        XCTAssertFalse(result.consolidatedText.contains("disabled"))
    }

    func testDuplicateIdentifiersConflictAndExcludeBothRules() {
        let id = UUID()
        let project = URL(fileURLWithPath: "/project")
        let rules = [
            ContextRule(id: id, name: "First", origin: .fsCode, scope: .project, content: "first", hash: ContextResolver.hash("first")),
            ContextRule(id: id, name: "Second", origin: .fsCode, scope: .project, content: "second", hash: ContextResolver.hash("second"))
        ]

        let result = ContextResolver().resolve(
            rules: rules,
            projectURL: project,
            paths: [project.appendingPathComponent("App.swift")]
        )

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries.allSatisfy { $0.state == .conflict })
        XCTAssertTrue(result.consolidatedText.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .conflict })
        XCTAssertFalse(result.canSend)
    }

    func testCanonicallyEquivalentUnicodeBodiesRemainDistinctByteSources() {
        let project = URL(fileURLWithPath: "/project")
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let rules = [
            ContextRule(name: "Composed", origin: .fsCode, scope: .project, priority: 0, content: composed, hash: ContextResolver.hash(composed)),
            ContextRule(name: "Decomposed", origin: .fsCode, scope: .project, priority: 1, content: decomposed, hash: ContextResolver.hash(decomposed))
        ]

        let result = ContextResolver().resolve(
            rules: rules,
            projectURL: project,
            paths: [project.appendingPathComponent("App.swift")]
        )

        XCTAssertEqual(result.entries.map(\.state), [.active, .active])
        XCTAssertFalse(result.diagnostics.contains { $0.kind == .duplicate })
    }
}

private func XCTAssertThrowsErrorAsync(_ body: @escaping () async throws -> Void) async {
    do { try await body(); XCTFail("Expected error") } catch {}
}
