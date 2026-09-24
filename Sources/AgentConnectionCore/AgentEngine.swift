import Foundation

/// Replaceable FS execution boundary. Provider/runtime implementations must preserve one logical
/// turn across injections and may expose only FS-approved host tools.
@MainActor
protocol AgentEngine: AnyObject {
    typealias NotificationHandler = @MainActor @Sendable (_ method: String, _ params: [String: Any]) -> Void
    var onNotification: NotificationHandler? { get set }
    func request(method: String, params: [String: Any]) async throws -> [String: Any]
    func stop()
}
