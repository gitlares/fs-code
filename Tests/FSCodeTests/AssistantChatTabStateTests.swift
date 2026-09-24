import Foundation
import XCTest
@testable import FSCode

@MainActor
final class AssistantChatTabStateTests: XCTestCase {
    func testClosedTabRemainsAvailableForReopen() {
        let first = UUID()
        let second = UUID()
        let closed = AssistantChatTabState(openThreadIDs: [first], selectedThreadID: first)

        let reconciled = AssistantChatTabState.reconciled(
            stored: closed,
            availableThreadIDs: [first, second],
            selectedThreadID: first
        )

        XCTAssertEqual(reconciled.openThreadIDs, [first])
        XCTAssertFalse(reconciled.openThreadIDs.contains(second))

        let reopened = AssistantChatTabState(
            openThreadIDs: reconciled.openThreadIDs + [second],
            selectedThreadID: second
        )
        XCTAssertEqual(reopened.openThreadIDs, [first, second])
        XCTAssertEqual(reopened.selectedThreadID, second)
    }

    func testPresentationStateIsScopedToProjectAndProfile() {
        let suite = "AssistantChatTabStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let projectA = URL(fileURLWithPath: "/tmp/project-a-\(UUID().uuidString)")
        let projectB = URL(fileURLWithPath: "/tmp/project-b-\(UUID().uuidString)")
        let profileA = UUID()
        let profileB = UUID()
        let stateA = AssistantChatTabState(openThreadIDs: [UUID()], selectedThreadID: nil)
        let stateB = AssistantChatTabState(openThreadIDs: [UUID(), UUID()], selectedThreadID: nil)

        let firstProject = AssistantChatTabStore(projectURL: projectA, defaults: defaults)
        let secondProject = AssistantChatTabStore(projectURL: projectB, defaults: defaults)
        firstProject.save(stateA, for: profileA)
        firstProject.save(stateB, for: profileB)

        XCTAssertEqual(firstProject.state(for: profileA), stateA)
        XCTAssertEqual(firstProject.state(for: profileB), stateB)
        XCTAssertNil(secondProject.state(for: profileA))
    }
}
