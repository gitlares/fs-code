import Foundation
import XCTest
@testable import ProjectLibrary

final class TodoListTests: XCTestCase {
    private func todo(
        _ id: UUID = UUID(),
        relevance: TodoRelevance = .normal,
        completed: Bool = false,
        createdAt: TimeInterval
    ) -> ProjectTodo {
        ProjectTodo(id: id, title: id.uuidString, isCompleted: completed, createdAt: Date(timeIntervalSince1970: createdAt), updatedAt: Date(timeIntervalSince1970: createdAt), relevance: relevance)
    }

    func testRelevanceSortAndDateSortUseStableUUIDTieBreak() {
        let low = todo(relevance: .low, createdAt: 30)
        let normal = todo(relevance: .normal, createdAt: 20)
        let highOlder = todo(relevance: .high, createdAt: 10)
        let highNewer = todo(relevance: .high, createdAt: 40)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tiedLaterID = todo(secondID, createdAt: 50)
        let tiedFirstID = todo(firstID, createdAt: 50)
        let items = [low, normal, highOlder, highNewer, tiedLaterID, tiedFirstID]

        XCTAssertEqual(TodoList.page(items, completed: false, order: .relevance, limit: 10).map(\.id), [highNewer.id, highOlder.id, firstID, secondID, normal.id, low.id])
        XCTAssertEqual(TodoList.page(items, completed: false, order: .newest, limit: 10).map(\.id), [firstID, secondID, highNewer.id, low.id, normal.id, highOlder.id])
        XCTAssertEqual(TodoList.page(items, completed: false, order: .oldest, limit: 10).map(\.id), [highOlder.id, normal.id, low.id, highNewer.id, firstID, secondID])
    }

    func testOpenAndClosedPagesAreIndependentAndLimitTenItems() {
        let open = (0..<12).map { todo(relevance: .normal, createdAt: TimeInterval($0)) }
        let closed = (0..<11).map { todo(relevance: .high, completed: true, createdAt: TimeInterval($0)) }
        let all = open + closed

        let openPage = TodoList.page(all, completed: false, order: .newest)
        let closedPage = TodoList.page(all, completed: true, order: .newest)
        XCTAssertEqual(openPage.count, 10)
        XCTAssertEqual(closedPage.count, 10)
        XCTAssertTrue(openPage.allSatisfy { !$0.isCompleted })
        XCTAssertTrue(closedPage.allSatisfy(\.isCompleted))
        XCTAssertEqual(openPage.map(\.id), Array(open.reversed().prefix(10)).map(\.id))
        XCTAssertEqual(closedPage.map(\.id), Array(closed.reversed().prefix(10)).map(\.id))

        var moved = open[0]
        moved.isCompleted = true
        let afterMove = TodoList.page(Array(open.dropFirst()) + [moved], completed: true, order: .newest, limit: 20)
        XCTAssertEqual(afterMove.map(\.id), [moved.id])
    }
}
