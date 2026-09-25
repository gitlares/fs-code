import AgentRunKit
import CryptoKit
import Darwin
import Foundation

struct NativeThreadHistory: Codable {
    let threadID: String
    var messages: [ChatMessage]
}

/// Local, non-secret provider history. The hashed filename accepts legacy thread identifiers
/// without treating them as paths; interrupted tool calls receive error results on restore.
struct NativeAgentHistoryStore {
    let root: URL
    private let base: URL

    init(projectID: UUID, profileID: UUID, rootOverride: URL? = nil) {
        let base = rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.base = base
        root = base
            .appendingPathComponent("FS Code", isDirectory: true)
            .appendingPathComponent("NativeAgentHistory", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    func load(threadID: String) throws -> [ChatMessage]? {
        try validateRoot(create: false)
        let file = fileURL(threadID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1_024 * 1_024 else { throw NativeAgentRuntime.RuntimeError.malformed }
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw NativeAgentRuntime.RuntimeError.malformed }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let history = try JSONDecoder().decode(NativeThreadHistory.self, from: data)
        guard history.threadID == threadID else { throw NativeAgentRuntime.RuntimeError.malformed }
        return repairInterruptedTools(history.messages)
    }

    func save(threadID: String, messages: [ChatMessage]) throws {
        guard messages.count <= 1_024 else { throw NativeAgentRuntime.RuntimeError.malformed }
        try validateRoot(create: true)
        let history = NativeThreadHistory(threadID: threadID, messages: messages)
        let data = try JSONEncoder().encode(history)
        guard data.count <= 8 * 1_024 * 1_024 else { throw NativeAgentRuntime.RuntimeError.malformed }
        try data.write(to: fileURL(threadID), options: .atomic)
    }

    private func fileURL(_ threadID: String) -> URL {
        let digest = SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }

    private func validateRoot(create: Bool) throws {
        var cursor = root
        while cursor.path != base.path && cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw NativeAgentRuntime.RuntimeError.malformed }
            cursor.deleteLastPathComponent()
        }
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if create && !FileManager.default.fileExists(atPath: root.path) { throw NativeAgentRuntime.RuntimeError.malformed }
    }

    /// Restores tool-call ordering after an interrupted runtime. A previous version appended
    /// synthetic results at the end of the history, which left intervening user messages ahead
    /// of their tool result and made the next provider request invalid.
    func repairInterruptedTools(_ messages: [ChatMessage]) -> [ChatMessage] {
        var repaired: [ChatMessage] = []
        var outstanding: [ToolCall] = []
        var relocatedSyntheticResults = Set<Int>()

        func syntheticResult(for call: ToolCall) -> ChatMessage {
            .tool(id: call.id, name: call.name, content: Self.interruptedToolMessage)
        }

        func deferredSyntheticResult(for call: ToolCall, after index: Int) -> (index: Int, message: ChatMessage)? {
            for candidate in messages.indices where candidate > index && !relocatedSyntheticResults.contains(candidate) {
                guard case let .tool(id, _, content) = messages[candidate],
                      id == call.id, content == Self.interruptedToolMessage
                else { continue }
                return (candidate, messages[candidate])
            }
            return nil
        }

        func closeOutstanding(before index: Int) {
            for call in outstanding {
                if let deferred = deferredSyntheticResult(for: call, after: index) {
                    relocatedSyntheticResults.insert(deferred.index)
                    repaired.append(deferred.message)
                } else {
                    repaired.append(syntheticResult(for: call))
                }
            }
            outstanding.removeAll()
        }

        for (index, message) in messages.enumerated() {
            if relocatedSyntheticResults.contains(index) { continue }
            switch message {
            case let .assistant(assistant):
                if !outstanding.isEmpty { closeOutstanding(before: index) }
                repaired.append(message)
                outstanding = assistant.toolCalls
            case let .tool(id, _, _):
                repaired.append(message)
                if outstanding.first?.id == id { outstanding.removeFirst() }
            case .system, .user, .userMultimodal:
                if !outstanding.isEmpty { closeOutstanding(before: index) }
                repaired.append(message)
            }
        }
        if !outstanding.isEmpty { closeOutstanding(before: messages.endIndex) }
        return repaired
    }

    private static let interruptedToolMessage = "Tool execution was interrupted before this session closed. It was not replayed."
}
