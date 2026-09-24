import Foundation

/// The input context reported for the latest request in a conversation.
/// Values originate exclusively from Codex's `thread/tokenUsage/updated` event.
public struct ConversationInputContextUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let modelContextWindow: Int
    public let modelID: String?

    public init(inputTokens: Int, modelContextWindow: Int, modelID: String?) {
        self.inputTokens = inputTokens
        self.modelContextWindow = modelContextWindow
        self.modelID = modelID
    }

    public var utilization: Double {
        Double(inputTokens) / Double(modelContextWindow)
    }
}

public enum ConversationActivityPhase: String, Codable, Sendable, Equatable {
    case reasoning
    case command
    case dynamicTool
    case mcp
}

/// One non-message runtime item. Reasoning content is deliberately never retained.
public struct ConversationTurnActivity: Identifiable, Codable, Sendable, Equatable {
    public let itemID: String
    public let phase: ConversationActivityPhase
    public var operation: String?
    public var status: String?
    public var output: String?
    public let startedAt: Date
    public var completedAt: Date?

    public init(
        itemID: String,
        phase: ConversationActivityPhase,
        operation: String? = nil,
        status: String? = nil,
        output: String? = nil,
        startedAt: Date,
        completedAt: Date? = nil
    ) {
        self.itemID = itemID
        self.phase = phase
        self.operation = operation
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var id: String { itemID }

    public var durationMs: Int? {
        guard let completedAt else { return nil }
        let milliseconds = completedAt.timeIntervalSince(startedAt) * 1_000
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return milliseconds >= Double(Int.max) ? Int.max : Int(milliseconds)
    }
}

/// Bounded activity telemetry for one user message and its remote Codex turn.
public struct ConversationTurnActivitySummary: Identifiable, Codable, Sendable, Equatable {
    public let userMessageID: UUID
    public var remoteTurnID: String?
    public var activities: [ConversationTurnActivity]

    public init(
        userMessageID: UUID,
        remoteTurnID: String? = nil,
        activities: [ConversationTurnActivity] = []
    ) {
        self.userMessageID = userMessageID
        self.remoteTurnID = remoteTurnID
        self.activities = activities
    }

    public var id: UUID { userMessageID }
}
