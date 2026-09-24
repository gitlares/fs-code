import Foundation

public enum AgentMode: String, Codable, CaseIterable, Sendable {
    case build
    case plan
    case ask
}
