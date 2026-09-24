import AppKit
import AgentConnectionCore
import XCTest
@testable import FSCode

@MainActor
final class AgentConnectionUITests: XCTestCase {
    func testPanelAttachesAndDetachesItsSharedConnectionObservation() async throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let manager = AgentConnectionManager(applicationSupportURL: support)
        let panel = AssistantConnectionView(manager: manager, projectURL: support)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = panel
        defer { host.close() }

        await Task.yield()
        XCTAssertTrue(panel.hasActiveConnectionObservation)

        host.contentView = NSView()
        XCTAssertFalse(panel.hasActiveConnectionObservation)
    }

    func testEmptyPanelFitsAtMinimumAssistantWidthWithoutCapturingReturn() async throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let panel = AssistantConnectionView(
            manager: AgentConnectionManager(applicationSupportURL: support),
            projectURL: support
        )
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = panel
        defer { host.close() }

        await Task.yield()
        panel.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(panel, of: NSPopUpButton.self).isEmpty)
        XCTAssertEqual(
            descendants(panel, of: NSButton.self)
                .filter { ["Connection", "Chat model", "Reasoning effort"].contains($0.accessibilityLabel()) }
                .count,
            3
        )
        let add = try XCTUnwrap(descendants(panel, of: NSButton.self).first { $0.title == "Connect Model…" })
        XCTAssertTrue(add.keyEquivalent.isEmpty)
        XCTAssertLessThanOrEqual(add.frame.maxX, panel.bounds.width + 0.5)

        host.setContentSize(NSSize(width: 760, height: 480))
        panel.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(add.frame.maxX, panel.bounds.width + 0.5)
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}
