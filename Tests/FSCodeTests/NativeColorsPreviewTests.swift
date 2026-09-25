import AppKit
import AgentConnectionCore
import ProjectLibrary
import QuartzCore
import XCTest
@testable import FSCode

@MainActor
final class NativeColorsPreviewTests: XCTestCase {
    func testRenderWorkspaceChromeInLightAndDarkWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["FS_CODE_RENDER_NATIVE_COLORS"] == "1" else {
            throw XCTSkip("Set FS_CODE_RENDER_NATIVE_COLORS=1 to export native chrome previews.")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-colors-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let appearances: [(name: NSAppearance.Name, fileStem: String)] = [
            (.aqua, "light"),
            (.darkAqua, "dark"),
            (.accessibilityHighContrastAqua, "high-contrast-light"),
            (.accessibilityHighContrastDarkAqua, "high-contrast-dark")
        ]
        for appearance in appearances {
            let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: projectURL) }
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let sourceURL = projectURL.appendingPathComponent("Marked.swift")
            let before = "import Foundation\n\nprint(\"before\")\n"
            let after = "import Foundation\n\nprint(\"after\")\n"
            try Data(before.utf8).write(to: sourceURL)

            let changes = try AgentFileChangeService(projectURL: projectURL)
            let proposal = try await changes.stageEdit(
                relativePath: "Marked.swift",
                oldText: before,
                newText: after,
                threadID: "preview-thread",
                turnID: "preview-turn"
            )
            let applied = try await changes.applyApproved(proposal)

            let project = Project(id: UUID(), name: "Native Colors", path: projectURL.path)
            let workspace = WorkspaceWindow(project: project, url: projectURL, launchesTerminal: false)
            let window = workspace.window
            window.appearance = NSAppearance(named: appearance.name)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            await settle(window)
            let editor = try XCTUnwrap(descendants(window.contentView, of: TextEditorView.self).first)
            await editor.open(sourceURL)
            editor.setAgentChangeHunks([
                sourceURL.resolvingSymlinksInPath().standardizedFileURL: applied.changeHunks
            ])
            await settle(window)

            let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            XCTAssertEqual(window.toolbarStyle, .unified)
            XCTAssertEqual(split.splitViewItems.count, 3)
            let outline = try XCTUnwrap(descendants(window.contentView, of: NSOutlineView.self).first)
            XCTAssertEqual(outline.style, .sourceList)
            XCTAssertEqual(outline.backgroundColor, .clear)
            XCTAssertFalse(descendants(window.contentView, of: AssistantConnectionView.self).isEmpty)
            let codeText = try XCTUnwrap(descendants(window.contentView, of: CodeTextView.self).first)
            XCTAssertFalse(codeText.agentChangeRanges.isEmpty)

            try writeSnapshot(
                window.contentView,
                to: output,
                named: "workspace-\(appearance.fileStem).png"
            )
        }
    }

    private func settle(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try? await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private func descendants<T: NSView>(_ root: NSView?, of type: T.Type) -> [T] {
        guard let root else { return [] }
        return (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    private func writeSnapshot(_ view: NSView?, to directory: URL, named name: String) throws {
        let view = try XCTUnwrap(view)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }
}
