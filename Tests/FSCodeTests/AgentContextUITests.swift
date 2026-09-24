import AppKit
import AgentContextCore
import XCTest
@testable import FSCode

@MainActor
final class AgentContextUITests: XCTestCase {
    func testWatcherFiltersRelativeBuildFoldersWithoutRejectingProjectParent() {
        let project = "/tmp/vendor/sample"
        let global = "/tmp/app-support/FS Code/context"

        XCTAssertTrue(AgentContextWatcher.isRelevantChange(
            path: "/tmp/vendor/sample/AGENTS.md", projectPath: project, globalPath: global
        ))
        XCTAssertTrue(AgentContextWatcher.isRelevantChange(
            path: "/tmp/vendor/sample/features/payments/CLAUDE.local.md", projectPath: project, globalPath: global
        ))
        XCTAssertTrue(AgentContextWatcher.isRelevantChange(
            path: "/tmp/vendor/sample/.claude/rules/security.md", projectPath: project, globalPath: global
        ))
        XCTAssertFalse(AgentContextWatcher.isRelevantChange(
            path: "/tmp/vendor/sample/node_modules/package/AGENTS.md", projectPath: project, globalPath: global
        ))
        XCTAssertFalse(AgentContextWatcher.isRelevantChange(
            path: "/tmp/vendor/sample/Sources/View.swift", projectPath: project, globalPath: global
        ))
        XCTAssertTrue(AgentContextWatcher.isRelevantChange(
            path: "/tmp/app-support/FS Code/context/global.md", projectPath: project, globalPath: global
        ))
    }

    func testRefreshPreservesDirtyInstructionsWhenSourceChangesOnDisk() async throws {
        _ = NSApplication.shared
        let id = UUID()
        let original = ContextRule(
            id: id,
            name: "Payments",
            url: URL(fileURLWithPath: "/tmp/payments.md"),
            origin: .fsCode,
            scope: .project,
            content: "Original",
            hash: ContextResolver.hash("Original")
        )
        let view = AgentContextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let host = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        defer { host.close() }

        view.apply(.init(rules: [original]))
        view.selectRule(id: id)
        await Task.yield()
        let editor = try XCTUnwrap(descendants(view, of: NSTextView.self).first {
            $0.accessibilityLabel() == "Context instructions"
        })
        editor.insertText("Draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))

        var changed = original
        changed.content = "Changed elsewhere"
        changed.hash = ContextResolver.hash(changed.content)
        view.apply(.init(rules: [changed]))

        XCTAssertEqual(editor.string, "Draft")
        XCTAssertFalse(view.canLeave)
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
