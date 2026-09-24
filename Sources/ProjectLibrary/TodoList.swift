import Foundation

public enum TodoSortOrder: Sendable {
    case relevance
    case newest
    case oldest
}

public enum TodoList {
    public static func page(
        _ items: [ProjectTodo],
        completed: Bool,
        order: TodoSortOrder,
        limit: Int = 10
    ) -> [ProjectTodo] {
        Array(items
            .filter { $0.isCompleted == completed }
            .sorted { precedes($0, $1, order: order) }
            .prefix(Swift.max(0, limit)))
    }

    private static func precedes(_ lhs: ProjectTodo, _ rhs: ProjectTodo, order: TodoSortOrder) -> Bool {
        switch order {
        case .relevance:
            let lhsRelevance = relevanceRank(lhs.relevance)
            let rhsRelevance = relevanceRank(rhs.relevance)
            if lhsRelevance != rhsRelevance { return lhsRelevance > rhsRelevance }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        case .newest:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        case .oldest:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func relevanceRank(_ relevance: TodoRelevance) -> Int {
        switch relevance {
        case .high: 3
        case .normal: 2
        case .low: 1
        }
    }
}
