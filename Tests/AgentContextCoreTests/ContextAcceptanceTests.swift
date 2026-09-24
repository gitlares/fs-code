import Foundation
import XCTest
@testable import AgentContextCore

final class ContextAcceptanceTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSCode-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
    }

    private func store() -> ContextStore {
        ContextStore(configuration: .init(
            projectURL: projectURL,
            globalStoreURL: projectURL.appendingPathComponent("global-context")
        ))
    }

    private func store(scan: ContextScanConfiguration) -> ContextStore {
        ContextStore(configuration: .init(
            projectURL: projectURL,
            globalStoreURL: projectURL.appendingPathComponent("global-context"),
            scan: scan
        ))
    }

    private func write(_ relativePath: String, _ content: String) throws -> URL {
        let url = projectURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEmptyLoadDoesNotCreateFilesystemStore() async throws {
        let snapshot = try await store().load()
        XCTAssertTrue(snapshot.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(".fs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("global-context").path))
    }

    func testCRUDPersistsAllMetadataAcrossNewStore() async throws {
        let initial = try await store().create(name: "Payments", scope: .glob, target: "Sources/**/*.swift", priority: 7, content: "v1")
        let markdownURL = projectURL.appendingPathComponent(".fs/context/\(initial.id.uuidString.lowercased()).md")
        XCTAssertEqual(initial.origin, .fsCode)
        XCTAssertEqual(initial.provider, .fsCode)
        XCTAssertEqual(initial.scope, .glob)
        XCTAssertEqual(initial.target, "Sources/**/*.swift")
        XCTAssertEqual(initial.priority, 7)
        XCTAssertTrue(initial.enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(".fs/context/manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))

        let reloadedStore = store()
        let loaded = try await reloadedStore.load().rules.first { $0.id == initial.id }
        XCTAssertEqual(loaded, initial)

        let updated = try await reloadedStore.update(id: initial.id, expectedHash: initial.hash, name: "Payments v2", scope: .file, target: "Sources/Payments.swift", priority: 11, enabled: false, content: "v2")
        XCTAssertEqual(updated.name, "Payments v2")
        XCTAssertEqual(updated.scope, .file)
        XCTAssertEqual(updated.target, "Sources/Payments.swift")
        XCTAssertEqual(updated.priority, 11)
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.origin, .fsCode)
        XCTAssertEqual(updated.provider, .fsCode)
        XCTAssertEqual(updated.content, "v2")
        XCTAssertEqual(updated.hash, ContextResolver.hash("v2"))

        let renamed = try await reloadedStore.rename(id: initial.id, name: "Payments final")
        XCTAssertEqual(renamed.name, "Payments final")
        try await reloadedStore.remove(id: initial.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
        let remaining = try await reloadedStore.load()
        XCTAssertTrue(remaining.rules.isEmpty)
    }

    func testRuleMovesBetweenGlobalAndProjectStoresWithSameIdentifier() async throws {
        let contextStore = store()
        let global = try await contextStore.create(name: "Shared", scope: .global, content: "global body")
        let globalMarkdown = projectURL.appendingPathComponent("global-context/\(global.id.uuidString.lowercased()).md")
        let projectMarkdown = projectURL.appendingPathComponent(".fs/context/\(global.id.uuidString.lowercased()).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalMarkdown.path))

        let projectRule = try await contextStore.update(
            id: global.id,
            expectedHash: global.hash,
            name: "Project Shared",
            scope: .folder,
            target: "Sources",
            priority: 3,
            enabled: true,
            content: "project body"
        )
        XCTAssertEqual(projectRule.id, global.id)
        XCTAssertEqual(projectRule.scope, .folder)
        XCTAssertEqual(projectRule.target, "Sources")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectMarkdown.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalMarkdown.path))
        let projectSnapshot = try await contextStore.load()
        let loadedProject = try XCTUnwrap(projectSnapshot.rules.first { $0.id == global.id })
        XCTAssertEqual(loadedProject.scope, .folder)
        XCTAssertEqual(loadedProject.content, "project body")

        let movedGlobal = try await contextStore.update(
            id: global.id,
            expectedHash: projectRule.hash,
            name: "Global Again",
            scope: .global,
            target: nil,
            priority: 1,
            enabled: true,
            content: "global again"
        )
        XCTAssertEqual(movedGlobal.id, global.id)
        XCTAssertEqual(movedGlobal.scope, .global)
        XCTAssertNil(movedGlobal.target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalMarkdown.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectMarkdown.path))
        let globalSnapshot = try await contextStore.load()
        let loadedGlobal = try XCTUnwrap(globalSnapshot.rules.first { $0.id == global.id })
        XCTAssertEqual(loadedGlobal.scope, .global)
        XCTAssertEqual(loadedGlobal.content, "global again")
    }

    func testExternalAgentsStartInactiveAndActivationSurvivesRescan() async throws {
        let url = try write("AGENTS.md", "external instructions")
        let contextStore = store()
        let firstScan = try await contextStore.scanExternal()
        let discovered = try XCTUnwrap(firstScan.rules.first { $0.url == url })
        XCTAssertEqual(discovered.origin, .external)
        XCTAssertFalse(discovered.enabled)
        let loadedBeforeActivation = try await contextStore.load()
        let loadedDiscovered = try XCTUnwrap(loadedBeforeActivation.rules.first { $0.url == url })
        XCTAssertFalse(loadedDiscovered.enabled)

        _ = try await contextStore.setActivation(id: discovered.id, enabled: true)
        let loadedAfterActivation = try await contextStore.load()
        let loadedActivated = try XCTUnwrap(loadedAfterActivation.rules.first { $0.url == url })
        XCTAssertTrue(loadedActivated.enabled)
        let rescanned = try await contextStore.scanExternal()
        let activated = try XCTUnwrap(rescanned.rules.first { $0.url == url })
        XCTAssertEqual(activated.id, discovered.id)
        XCTAssertTrue(activated.enabled)
        _ = try await contextStore.setActivation(id: activated.id, enabled: false)
        let disabledResolution = try await contextStore.resolve(paths: [url])
        XCTAssertTrue(disabledResolution.consolidatedText.isEmpty)
    }

    func testExternalScanStopsAtConfiguredSourceCount() async throws {
        _ = try write("AGENTS.md", "one")
        _ = try write("CLAUDE.md", "two")
        _ = try write("GEMINI.md", "three")
        let contextStore = store(scan: .init(maximumRuleCount: 2))

        let snapshot = try await contextStore.scanExternal()

        XCTAssertEqual(snapshot.rules.count, 2)
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.kind == .incompleteScan && $0.message.contains("instruction sources")
        })
    }

    func testAggregateCatalogByteLimitIsSharedAcrossOwnedAndExternalRules() async throws {
        let contextStore = store(scan: .init(maximumRuleBytes: 64, maximumTotalRuleBytes: 8, maximumRuleCount: 10))
        let owned = try await contextStore.create(name: "Owned", scope: .project, content: "12345")
        let externalURL = try write("AGENTS.md", "67890")

        let snapshot = try await contextStore.load()
        XCTAssertTrue(snapshot.rules.contains { $0.id == owned.id })
        XCTAssertFalse(snapshot.rules.contains { $0.url == externalURL })
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.kind == .incompleteScan && $0.message.contains("aggregate context catalog limit")
        })

        let resolution = await contextStore.resolve(snapshot: snapshot, paths: [externalURL])
        XCTAssertFalse(resolution.canSend)
    }

    func testExternalOverrideReplacesSameFolderAndKeepsRootParent() async throws {
        let root = try write("AGENTS.md", "root guidance")
        let nested = try write("nested/AGENTS.md", "old nested guidance")
        let override = try write("nested/AGENTS.override.md", "replacement guidance")
        let target = try write("nested/child.swift", "// target")
        let contextStore = store()
        let scan = try await contextStore.scanExternal()
        for rule in scan.rules { _ = try await contextStore.setActivation(id: rule.id, enabled: true) }
        let resolution = try await contextStore.resolve(paths: [target])
        XCTAssertTrue(resolution.consolidatedText.contains(root.path))
        XCTAssertTrue(resolution.consolidatedText.contains(override.path))
        XCTAssertFalse(resolution.consolidatedText.contains(nested.path))
        XCTAssertTrue(resolution.consolidatedText.contains("root guidance"))
        XCTAssertTrue(resolution.consolidatedText.contains("replacement guidance"))
    }

    func testFolderBoundaryExactFileAndSwiftGlob() throws {
        let project = projectURL!
        let rules = [
            ContextRule(name: "Sources", origin: .fsCode, scope: .folder, target: "Sources", content: "folder", hash: ContextResolver.hash("folder")),
            ContextRule(name: "Swift", origin: .fsCode, scope: .glob, target: "**/*.swift", content: "swift", hash: ContextResolver.hash("swift")),
            ContextRule(name: "Exact", origin: .fsCode, scope: .file, target: "Sources/App.swift", content: "exact", hash: ContextResolver.hash("exact"))
        ]
        let app = try write("Sources/App.swift", "app")
        let nested = try write("Sources/Nested/Thing.swift", "nested")
        let rootSwift = try write("Root.swift", "root")
        let extra = try write("SourcesExtra/Extra.swift", "extra")
        let result = ContextResolver().resolve(rules: rules, projectURL: project, paths: [app, nested, rootSwift, extra])
        let folderEntry = try XCTUnwrap(result.entries.first { $0.rule.name == "Sources" })
        let exactEntry = try XCTUnwrap(result.entries.first { $0.rule.name == "Exact" })
        let swiftEntry = try XCTUnwrap(result.entries.first { $0.rule.name == "Swift" })
        XCTAssertEqual(result.entries.filter { $0.rule.name == "Sources" }.count, 1)
        XCTAssertEqual(result.entries.filter { $0.rule.name == "Exact" }.count, 1)
        XCTAssertEqual(result.entries.filter { $0.rule.name == "Swift" }.count, 1)
        XCTAssertTrue(folderEntry.matchedPaths.contains(app.path))
        XCTAssertTrue(folderEntry.matchedPaths.contains(nested.path))
        XCTAssertFalse(folderEntry.matchedPaths.contains(extra.path))
        XCTAssertEqual(exactEntry.matchedPaths, [app.path])
        XCTAssertTrue(swiftEntry.matchedPaths.contains(app.path))
        XCTAssertTrue(swiftEntry.matchedPaths.contains(nested.path))
        XCTAssertTrue(swiftEntry.matchedPaths.contains(rootSwift.path))
        XCTAssertTrue(swiftEntry.matchedPaths.contains(extra.path))
        XCTAssertEqual(result.entries.first?.rule.name, "Sources")
    }

    func testConsolidatedHeadersAndUTF8CountAreDeterministic() throws {
        let source = projectURL.appendingPathComponent("CLAUDE.md")
        let rule = ContextRule(name: "Unicode", url: source, origin: .external, provider: .claude, scope: .project, content: "café", hash: ContextResolver.hash("café"))
        let resolver = ContextResolver()
        let paths = [projectURL.appendingPathComponent("App.swift")]
        let first = resolver.resolve(rules: [rule], projectURL: projectURL, paths: paths)
        let second = resolver.resolve(rules: [rule], projectURL: projectURL, paths: paths)
        XCTAssertEqual(first.consolidatedText, second.consolidatedText)
        XCTAssertTrue(first.consolidatedText.contains("[claude]"))
        XCTAssertTrue(first.consolidatedText.contains("source=\"\(source.path)\""))
        XCTAssertEqual(first.utf8ByteCount, first.consolidatedText.lengthOfBytes(using: .utf8))
        XCTAssertEqual(first.utf8ByteCount, second.utf8ByteCount)
    }

    func testOversizeReportsDiagnosticAndDoesNotSilentlyTruncate() throws {
        let content = String(repeating: "á", count: 40)
        let rule = ContextRule(name: "Large", origin: .fsCode, scope: .global, content: content, hash: ContextResolver.hash(content))
        let result = ContextResolver(configuration: .init(maximumUTF8Bytes: 16)).resolve(
            rules: [rule], projectURL: projectURL, paths: [projectURL.appendingPathComponent("App.swift")]
        )
        XCTAssertFalse(result.canSend)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .oversize })
        XCTAssertTrue(result.consolidatedText.contains(content))
        XCTAssertGreaterThan(result.utf8ByteCount, 16)
    }

    func testInvalidManifestIsNotOverwritten() async throws {
        let manifest = projectURL.appendingPathComponent(".fs/context/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("not-json".utf8)
        try invalid.write(to: manifest)
        do {
            _ = try await store().load()
            XCTFail("Expected corrupt manifest")
        } catch ContextStoreError.corruptManifest {
            XCTAssertEqual(try Data(contentsOf: manifest), invalid)
        }
    }

    func testExternalSymlinkEscapeIsExcluded() async throws {
        let outside = projectURL.deletingLastPathComponent().appendingPathComponent("FSCode-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try write("visible.md", "visible")
        try FileManager.default.createSymbolicLink(at: projectURL.appendingPathComponent("linked"), withDestinationURL: outside)
        _ = try writeOutside(outside, "AGENTS.md", "must not escape")
        let scanned = try await store().scanExternal()
        XCTAssertFalse(scanned.rules.contains { $0.url?.path.hasPrefix(outside.path) == true })
    }

    func testOwnedStoreRejectsProjectContextSymlinkEscape() async throws {
        let outside = projectURL.deletingLastPathComponent().appendingPathComponent("FSCode-store-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent(".fs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projectURL.appendingPathComponent(".fs/context"), withDestinationURL: outside)

        await XCTAssertThrowsErrorInAcceptance {
            _ = try await self.store().create(name: "Escaped", scope: .project, content: "nope")
        }
    }

    func testOwnedStoreRejectsManifestSymlinkEscape() async throws {
        let outside = projectURL.deletingLastPathComponent().appendingPathComponent("FSCode-manifest-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapedManifest = outside.appendingPathComponent("manifest.json")
        try #"{"version":1,"rules":[],"externalActivations":{}}"#.write(to: escapedManifest, atomically: true, encoding: .utf8)
        let manifest = projectURL.appendingPathComponent(".fs/context/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: escapedManifest)

        await XCTAssertThrowsErrorInAcceptance {
            _ = try await self.store().load()
        }
    }

    func testUnsupportedExternalMetadataStaysOutOfEffectiveContextAfterActivation() async throws {
        let ruleURL = try write(".claude/rules/bad.md", """
        ---
        paths: { Sources: "*.swift" }
        ---
        unsupported claude rule
        """)
        let target = try write("Sources/App.swift", "app")
        let contextStore = store()
        let scan = try await contextStore.scanExternal()
        let rule = try XCTUnwrap(scan.rules.first { $0.url == ruleURL })
        XCTAssertEqual(rule.applicability, .unsupported)
        XCTAssertTrue(rule.diagnostics.contains { $0.kind == .unsupportedSyntax })

        _ = try await contextStore.setActivation(id: rule.id, enabled: true)
        let resolution = try await contextStore.resolve(paths: [target])
        let entry = try XCTUnwrap(resolution.entries.first { $0.rule.id == rule.id })
        XCTAssertEqual(entry.state, .unsupported)
        XCTAssertFalse(resolution.consolidatedText.contains("unsupported claude rule"))
    }

    func testQuotedCommaGlobIsNotSplitBeforeUnquoting() async throws {
        let ruleURL = try write(".github/instructions/quoted.instructions.md", """
        ---
        applyTo: "Sources/A,B.swift"
        ---
        quoted path instruction
        """)
        let target = try write("Sources/A,B.swift", "app")
        let other = try write("Sources/A.swift", "app")
        let contextStore = store()
        let scan = try await contextStore.scanExternal()
        let rule = try XCTUnwrap(scan.rules.first { $0.url == ruleURL })
        XCTAssertEqual(rule.matchPatterns, ["Sources/A,B.swift"])

        _ = try await contextStore.setActivation(id: rule.id, enabled: true)
        let matched = try await contextStore.resolve(paths: [target])
        XCTAssertTrue(matched.consolidatedText.contains("quoted path instruction"))
        let unmatched = try await contextStore.resolve(paths: [other])
        XCTAssertFalse(unmatched.consolidatedText.contains("quoted path instruction"))
    }

    func testYamlListGlobsAreSupportedAndDuplicateOrBlockMetadataFailsClosed() async throws {
        let listURL = try write(".claude/rules/list.md", """
        ---
        paths:
          - Sources/**/*.swift
          - Tests/**/*.swift
        ---
        list rule
        """)
        let duplicateURL = try write(".cursor/rules/duplicate.mdc", """
        ---
        globs: Sources/**/*.swift
        globs: Tests/**/*.swift
        ---
        duplicate rule
        """)
        let blockURL = try write(".github/instructions/block.instructions.md", """
        ---
        applyTo: |
          Sources/**/*.swift
        ---
        block rule
        """)
        let contextStore = store()
        let scan = try await contextStore.scanExternal()
        let listRule = try XCTUnwrap(scan.rules.first { $0.url == listURL })
        XCTAssertEqual(listRule.matchPatterns, ["Sources/**/*.swift", "Tests/**/*.swift"])
        XCTAssertEqual(try XCTUnwrap(scan.rules.first { $0.url == duplicateURL }).applicability, .unsupported)
        XCTAssertEqual(try XCTUnwrap(scan.rules.first { $0.url == blockURL }).applicability, .unsupported)

        _ = try await contextStore.setActivation(id: listRule.id, enabled: true)
        let matched = try await contextStore.resolve(paths: [try write("Sources/App.swift", "app")])
        XCTAssertTrue(matched.consolidatedText.contains("list rule"))
    }

    func testImportDetectionIgnoresInlineAndFencedCodeButCatchesProse() async throws {
        let inlineURL = try write("CLAUDE.md", "Keep literal `@docs/import.md` in examples.")
        let proseURL = try write("Nested/CLAUDE.md", "Please also read @docs/import.md before editing.")
        _ = try write("Nested/File.swift", "app")
        let scan = try await store().scanExternal()
        let inline = try XCTUnwrap(scan.rules.first { $0.url == inlineURL })
        let prose = try XCTUnwrap(scan.rules.first { $0.url == proseURL })
        XCTAssertEqual(inline.applicability, .automatic)
        XCTAssertEqual(prose.applicability, .unsupported)
        XCTAssertTrue(prose.diagnostics.contains { $0.kind == .unsupportedSyntax })
    }

    func testInvalidCursorAlwaysApplyIsUnsupported() async throws {
        let ruleURL = try write(".cursor/rules/bad.mdc", """
        ---
        alwaysApply: maybe
        ---
        cursor rule
        """)
        let contextStore = store()
        let scan = try await contextStore.scanExternal()
        let rule = try XCTUnwrap(scan.rules.first { $0.url == ruleURL })
        XCTAssertEqual(rule.applicability, .unsupported)

        _ = try await contextStore.setActivation(id: rule.id, enabled: true)
        let resolution = try await contextStore.resolve(paths: [projectURL.appendingPathComponent("App.swift")])
        XCTAssertFalse(resolution.consolidatedText.contains("cursor rule"))
    }

    func testCodexProjectConfigContextSettingsProduceExplicitDiagnostic() async throws {
        _ = try write(".codex/config.toml", #"project_doc_fallback_filenames = ["README.agents.md"]"#)
        let scan = try await store().scanExternal()
        XCTAssertTrue(scan.diagnostics.contains {
            $0.kind == .incompleteScan && $0.message.contains(".codex/config.toml")
        })
    }

    func testCodexProjectConfigSymlinkOutsideProjectIsNotRead() async throws {
        let outside = projectURL.deletingLastPathComponent().appendingPathComponent("FSCode-config-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapedConfig = try writeOutside(outside, "config.toml", #"project_doc_fallback_filenames = ["SECRET.md"]"#)
        let config = projectURL.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: escapedConfig)

        let scan = try await store().scanExternal()
        XCTAssertTrue(scan.diagnostics.contains {
            $0.kind == .pathEscape && $0.message.contains(".codex/config.toml")
        })
        XCTAssertFalse(scan.diagnostics.contains {
            $0.message.contains("not interpreted")
        })
    }

    private func writeOutside(_ directory: URL, _ name: String, _ content: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private func XCTAssertThrowsErrorInAcceptance(_ body: @escaping () async throws -> Void) async {
    do {
        try await body()
        XCTFail("Expected error")
    } catch {}
}
