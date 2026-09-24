import Foundation
import CoreFoundation

public enum ConversationRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum ConversationMessagePhase: String, Codable, Sendable {
    case commentary
    case finalAnswer = "final_answer"
}

public struct ConversationThread: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct ConversationMessage: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let role: ConversationRole
    public var text: String
    public let createdAt: Date
    public var phase: ConversationMessagePhase?
    /// The remote turn that produced this user/assistant message, when known. Legacy local
    /// history deliberately decodes without one.
    public var turnID: String?

    public init(id: UUID = UUID(), role: ConversationRole, text: String, createdAt: Date = Date(), phase: ConversationMessagePhase? = nil, turnID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.phase = phase
        self.turnID = turnID
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, phase, turnID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ConversationRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        phase = try container.decodeIfPresent(String.self, forKey: .phase).flatMap(ConversationMessagePhase.init(rawValue:))
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(phase?.rawValue, forKey: .phase)
        try container.encodeIfPresent(turnID, forKey: .turnID)
    }
}

/// A locally persisted request waiting for the current Codex turn to finish.
/// Its identifier is also used as `clientUserMessageId` when Codex accepts it.
public struct ConversationQueuedMessage: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Codex advertises reasoning efforts as non-empty strings so this value deliberately
/// remains extensible instead of freezing the app to today's catalog values.
public struct ConversationReasoningEffort: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

public struct ConversationModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let supportedEfforts: [ConversationReasoningEffort]
    public let defaultEffort: ConversationReasoningEffort?
    public let isDefault: Bool

    public init(
        id: String,
        displayName: String,
        supportedEfforts: [ConversationReasoningEffort],
        defaultEffort: ConversationReasoningEffort?,
        isDefault: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }
}

public enum ConversationActivity: Sendable, Equatable {
    case idle
    case starting
    case responding(progress: String?)
    case stopping
    case failed(message: String)

    public var statusText: String {
        switch self {
        case .idle:
            "Ready"
        case .starting:
            "Starting…"
        case .responding(let progress):
            progress ?? "Responding…"
        case .stopping:
            "Stopping…"
        case .failed(let message):
            message
        }
    }
}

public enum ConversationFileChangeDecision: Sendable, Equatable {
    case apply
    case reject
}

public enum ConversationFileMutationOperation: Sendable, Equatable {
    case apply
    case revert
}

public struct ConversationFileMutationResult: Sendable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let operation: ConversationFileMutationOperation
    public let hunkID: String?

    public init(
        id: UUID,
        relativePath: String,
        operation: ConversationFileMutationOperation,
        hunkID: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.operation = operation
        self.hunkID = hunkID
    }
}

public struct ConversationTurnFileChanges: Identifiable, Sendable, Equatable {
    public let threadID: String
    public let turnID: String
    public let records: [AgentFileChangeRecord]

    public var id: String { "\(threadID):\(turnID)" }

    public init(threadID: String, turnID: String, records: [AgentFileChangeRecord]) {
        self.threadID = threadID
        self.turnID = turnID
        self.records = records
    }
}

public enum ConversationFileChangeCapability: Sendable, Equatable {
    case available
    case requiresNewChat
    case unavailable(message: String)
}

public enum AgentConversationError: LocalizedError, Equatable, Sendable {
    case corruptStore
    case externalChangeConflict
    case projectMismatch
    case storageLimit
    case noSelectedProfile
    case noSelectedConversation
    case unavailable(String)
    case unexpectedInstructionSources

    public var errorDescription: String? {
        switch self {
        case .corruptStore:
            "Saved conversations could not be read. They were left unchanged."
        case .externalChangeConflict:
            "Conversations changed outside this window. Your current chat is preserved in memory."
        case .projectMismatch:
            "Saved conversations belong to a different project location. They were left unchanged."
        case .storageLimit:
            "This project has reached the local conversation history limit."
        case .noSelectedProfile:
            "Select a connection before starting a chat."
        case .noSelectedConversation:
            "Start or select a chat first."
        case .unavailable(let message):
            message
        case .unexpectedInstructionSources:
            "Codex loaded project instructions that FS Code did not authorize for this read-only chat. The message was not sent."
        }
    }
}

@MainActor
protocol AgentConversationTransport: AnyObject {
    var selectedProfileID: UUID? { get }
    var connectionState: AgentConnectionState { get }
    var connectionModels: [ConnectionModel] { get }
    var profileSelectedModelID: String? { get }

    @discardableResult
    func addConnectionObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID
    func removeConnectionObserver(_ id: UUID)
    @discardableResult
    func addRuntimeObserver(
        _ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void
    ) -> UUID
    func removeRuntimeObserver(_ id: UUID)
    @discardableResult
    func setDynamicToolHandler(
        _ handler: @escaping @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult
    ) -> UUID
    func removeDynamicToolHandler(_ token: UUID)
    func shutdown() async
    func request(
        method: String,
        params: [String: Any],
        expectedProfileID: UUID,
        expectedSessionID: UUID?
    ) async throws -> AgentConnectionRuntimeResponse
}

@MainActor
private final class LiveAgentConversationTransport: AgentConversationTransport {
    private let manager: AgentConnectionManager
    private let clientID: UUID
    private var released = false

    init(manager: AgentConnectionManager) {
        self.manager = manager
        clientID = manager.acquireClient()
    }

    var selectedProfileID: UUID? { manager.selectedProfileID }
    var connectionState: AgentConnectionState { manager.state }
    var connectionModels: [ConnectionModel] { manager.models }
    var profileSelectedModelID: String? {
        manager.profiles.first(where: { $0.id == manager.selectedProfileID })?.selectedModelID
    }

    func addConnectionObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID {
        manager.addObserver(observer)
    }

    func removeConnectionObserver(_ id: UUID) {
        manager.removeObserver(id)
    }

    func addRuntimeObserver(
        _ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void
    ) -> UUID {
        manager.addRuntimeObserver(observer)
    }

    func removeRuntimeObserver(_ id: UUID) {
        manager.removeRuntimeObserver(id)
    }

    func setDynamicToolHandler(
        _ handler: @escaping @MainActor @Sendable (AgentDynamicToolRequest) async -> AgentDynamicToolResult
    ) -> UUID {
        manager.setDynamicToolHandler(handler)
    }

    func removeDynamicToolHandler(_ token: UUID) {
        manager.removeDynamicToolHandler(token)
    }

    func shutdown() async {
        guard !released else { return }
        released = true
        await manager.releaseClient(clientID)
    }

    func request(
        method: String,
        params: [String: Any],
        expectedProfileID: UUID,
        expectedSessionID: UUID?
    ) async throws -> AgentConnectionRuntimeResponse {
        try await manager.requestSelectedRuntime(
            method: method,
            params: params,
            expectedProfileID: expectedProfileID,
            expectedSessionID: expectedSessionID
        )
    }

    isolated deinit {
        guard !released else { return }
        let manager = manager
        let clientID = clientID
        Task { @MainActor in
            await manager.releaseClient(clientID)
        }
    }
}

private struct StoredConversation: Codable, Sendable {
    var id: UUID
    var profileID: UUID
    var remoteThreadID: String?
    var lastRemoteTurnID: String?
    var dynamicToolsVersion: Int?
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelID: String?
    var reasoningEffort: ConversationReasoningEffort?
    var draft: String
    var messages: [ConversationMessage]
    var inputContextUsage: ConversationInputContextUsage?
    var activitySummaries: [ConversationTurnActivitySummary]?
    var queuedMessages: [ConversationQueuedMessage]?
    var queueIsPaused: Bool?
    var queueError: String?
    var mode: AgentMode?
}

private struct StoredConversationDocument: Codable, Sendable {
    var version: Int
    var projectPath: String
    var selectedThreadIDs: [String: UUID]
    var conversations: [StoredConversation]
}

private actor AgentConversationStore {
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumConversations = 100
    static let maximumMessagesPerConversation = 500
    static let maximumTextBytes = 512 * 1_024

    let storageURL: URL
    private let projectURL: URL
    private let fileManager: FileManager
    private var lastReadData: Data?

    init(projectURL: URL, storageURL: URL? = nil, fileManager: FileManager = .default) {
        let canonicalProjectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.projectURL = canonicalProjectURL
        self.storageURL = storageURL ?? canonicalProjectURL
            .appendingPathComponent(".fscode", isDirectory: true)
            .appendingPathComponent("conversations.json")
        self.fileManager = fileManager
    }

    func load() throws -> StoredConversationDocument {
        guard let data = try currentData() else {
            lastReadData = nil
            return StoredConversationDocument(
                version: 1,
                projectPath: projectURL.path,
                selectedThreadIDs: [:],
                conversations: []
            )
        }

        let document: StoredConversationDocument
        do {
            document = try JSONDecoder().decode(StoredConversationDocument.self, from: data)
        } catch {
            throw AgentConversationError.corruptStore
        }
        try validate(document)
        guard document.projectPath == projectURL.path else {
            throw AgentConversationError.projectMismatch
        }
        lastReadData = data
        return document
    }

    func save(_ document: StoredConversationDocument) throws {
        guard fitsStorageLimits(document) else { throw AgentConversationError.storageLimit }
        try validate(document)
        guard document.projectPath == projectURL.path else {
            throw AgentConversationError.projectMismatch
        }
        guard try currentData() == lastReadData else {
            throw AgentConversationError.externalChangeConflict
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumBytes else { throw AgentConversationError.storageLimit }

        let directory = storageURL.deletingLastPathComponent()
        try ensureSafeDirectory(directory)
        try data.write(to: storageURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        lastReadData = data
    }

    private func currentData() throws -> Data? {
        guard fileManager.fileExists(atPath: storageURL.path) else { return nil }
        do {
            let values = try storageURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Self.maximumBytes + 1) <= Self.maximumBytes else {
                throw AgentConversationError.corruptStore
            }
            return try Data(contentsOf: storageURL, options: .mappedIfSafe)
        } catch let error as AgentConversationError {
            throw error
        } catch {
            throw AgentConversationError.corruptStore
        }
    }

    private func ensureSafeDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AgentConversationError.corruptStore
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let root = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        guard resolved.path == projectURL.path || resolved.path.hasPrefix(root) else {
            throw AgentConversationError.corruptStore
        }
    }

    private func validate(_ document: StoredConversationDocument) throws {
        guard document.version == 1,
              document.conversations.count <= Self.maximumConversations,
              Set(document.conversations.map(\.id)).count == document.conversations.count else {
            throw AgentConversationError.corruptStore
        }
        let ids = Set(document.conversations.map(\.id))
        guard document.selectedThreadIDs.values.allSatisfy(ids.contains) else {
            throw AgentConversationError.corruptStore
        }
        for (profileID, conversationID) in document.selectedThreadIDs {
            guard document.conversations.contains(where: {
                $0.id == conversationID && $0.profileID.uuidString == profileID
            }) else {
                throw AgentConversationError.corruptStore
            }
        }
        var remoteOwners = Set<String>()
        for conversation in document.conversations {
            guard !conversation.title.isEmpty,
                  conversation.title.utf8.count <= 512,
                  conversation.draft.utf8.count <= Self.maximumTextBytes,
                  conversation.messages.count <= Self.maximumMessagesPerConversation,
                  Set(conversation.messages.map(\.id)).count == conversation.messages.count,
                  conversation.messages.allSatisfy({ $0.text.utf8.count <= Self.maximumTextBytes }),
                  (conversation.queuedMessages ?? []).count <= Self.maximumMessagesPerConversation,
                  (conversation.queuedMessages ?? []).allSatisfy({ $0.text.utf8.count <= Self.maximumTextBytes }),
                  Set((conversation.queuedMessages ?? []).map(\.id)).count == (conversation.queuedMessages ?? []).count,
                  conversation.remoteThreadID.map({ !$0.isEmpty }) ?? true,
                  conversation.lastRemoteTurnID.map({ !$0.isEmpty }) ?? true else {
                throw AgentConversationError.corruptStore
            }
            if let usage = conversation.inputContextUsage,
               usage.inputTokens < 0 || usage.modelContextWindow <= 0 {
                throw AgentConversationError.corruptStore
            }
            if let summaries = conversation.activitySummaries,
               summaries.count > 64 || Set(summaries.map(\.userMessageID)).count != summaries.count ||
               summaries.contains(where: { summary in
                   summary.remoteTurnID?.isEmpty == true || summary.activities.count > 128 ||
                   !conversation.messages.contains(where: { $0.id == summary.userMessageID && $0.role == .user }) ||
                   Set(summary.activities.map(\.itemID)).count != summary.activities.count ||
                   summary.activities.contains(where: { activity in
                       activity.itemID.isEmpty || (activity.operation?.utf8.count ?? 0) > 4_096 ||
                       (activity.status?.utf8.count ?? 0) > 4_096 || (activity.output?.utf8.count ?? 0) > 16_384
                   })
               }) {
                throw AgentConversationError.corruptStore
            }
            if let remoteThreadID = conversation.remoteThreadID {
                guard remoteOwners.insert("\(conversation.profileID.uuidString):\(remoteThreadID)").inserted else {
                    throw AgentConversationError.corruptStore
                }
            }
        }
    }

    private func fitsStorageLimits(_ document: StoredConversationDocument) -> Bool {
        document.conversations.count <= Self.maximumConversations
            && document.conversations.allSatisfy { conversation in
                conversation.draft.utf8.count <= Self.maximumTextBytes
                    && conversation.messages.count <= Self.maximumMessagesPerConversation
                    && (conversation.queuedMessages ?? []).count <= Self.maximumMessagesPerConversation
                    && conversation.messages.allSatisfy {
                        $0.text.utf8.count <= Self.maximumTextBytes
                    }
                    && (conversation.queuedMessages ?? []).allSatisfy {
                        $0.text.utf8.count <= Self.maximumTextBytes
                    }
            }
    }
}

private enum BufferedConversationEvent {
    case reasoningSummaryPart(turnID: String, itemID: String, summaryIndex: Int)
    case reasoningSummaryDelta(turnID: String, itemID: String, summaryIndex: Int, text: String)
    case assistantPhase(turnID: String, itemID: String, phase: ConversationMessagePhase)
    case delta(turnID: String, itemID: String, text: String)
    case finalMessage(turnID: String, itemID: String, text: String, phase: ConversationMessagePhase?)
    case progress(turnID: String, text: String)
    case activityStarted(turnID: String, itemID: String, phase: ConversationActivityPhase, operation: String?)
    case activityCompleted(turnID: String, itemID: String, phase: ConversationActivityPhase, operation: String?, status: String?, output: String?)
    case failure(turnID: String, message: String)
    case completed(turnID: String, status: String, error: String?, finalMessage: (itemID: String, text: String)?)

    var turnID: String {
        switch self {
        case .reasoningSummaryPart(let turnID, _, _),
             .reasoningSummaryDelta(let turnID, _, _, _),
             .assistantPhase(let turnID, _, _),
             .delta(let turnID, _, _),
             .finalMessage(let turnID, _, _, _),
             .progress(let turnID, _),
             .activityStarted(let turnID, _, _, _),
             .activityCompleted(let turnID, _, _, _, _, _),
             .failure(let turnID, _),
             .completed(let turnID, _, _, _):
            turnID
        }
    }
}

private struct ActiveConversationTurn {
    let generation: Int
    let conversationID: UUID
    let profileID: UUID
    var sessionID: UUID?
    var remoteThreadID: String?
    var remoteTurnID: String?
    var assistantMessageIDs: [String: UUID] = [:]
    var assistantMessagePhases: [String: ConversationMessagePhase] = [:]
    let userMessageID: UUID
    var bufferedEvents: [BufferedConversationEvent] = []
    var stopRequested = false
    var interruptSent = false
    var outputTruncated = false
    var hasFinalAnswerOutput = false
}

private struct RetainedConversationTurn {
    let generation: Int
    let conversationID: UUID
    let profileID: UUID
    let sessionID: UUID
    let remoteThreadID: String
    let remoteTurnID: String
}

private struct FileToolInvocationIdentity: Sendable, Equatable {
    let generation: Int
    let conversationID: UUID
    let profileID: UUID
    let sessionID: UUID
    let threadID: String
    let turnID: String
}

/// A per-project conversation service backed by the selected authenticated Codex runtime.
/// Runtime turns remain sandboxed read-only. The single `fs_edit_file` dynamic tool can only
/// write through `AgentFileChangeService` after the host UI explicitly approves a staged diff.
@MainActor
public final class AgentConversationManager {
    public typealias Observer = @MainActor @Sendable () -> Void

    public private(set) var threads: [ConversationThread] = []
    public private(set) var selectedThreadID: UUID?
    public private(set) var messages: [ConversationMessage] = []
    public private(set) var draft = ""
    public private(set) var selectedModelID: String?
    public private(set) var selectedEffort: ConversationReasoningEffort?
    public private(set) var activity: ConversationActivity = .idle
    public private(set) var fileChangeProposals: [AgentFileChangeProposal] = []
    public private(set) var appliedChanges: [AgentFileChangeRecord] = []
    public private(set) var lastRequestInputContext: ConversationInputContextUsage?
    public private(set) var turnActivitySummaries: [ConversationTurnActivitySummary] = []
    public private(set) var queuedMessages: [ConversationQueuedMessage] = []
    public private(set) var queuedMessageInFlightID: UUID?
    public private(set) var queueIsPaused = false
    public private(set) var queueError: String?
    public private(set) var liveProgressText: String?
    public private(set) var liveProgressUserMessageID: UUID?
    public private(set) var mode: AgentMode = .build
    private var liveProgressItemID: String?
    private var liveProgressSummaryIndex: Int?
    /// Built-in runtime tools stay read-only, while the audited `fs_edit_file` host tool can
    /// apply text changes automatically after the workspace's dirty-buffer safety check.
    public let isReadOnly = false

    public var reviewFileChange: (@MainActor @Sendable (AgentFileChangeProposal) async -> ConversationFileChangeDecision)?
    public var authorizeFileMutation: (@MainActor @Sendable (
        _ relativePath: String,
        _ operation: ConversationFileMutationOperation
    ) async -> Bool)?
    public var didCompleteFileMutation: (@MainActor @Sendable (ConversationFileMutationResult) -> Void)?

    public var models: [ConversationModelOption] {
        transport.connectionModels.map { model in
            ConversationModelOption(
                id: model.id,
                displayName: model.displayName,
                supportedEfforts: model.supportedReasoningEfforts.compactMap(ConversationReasoningEffort.init),
                defaultEffort: model.defaultReasoningEffort.flatMap(ConversationReasoningEffort.init),
                isDefault: model.isDefault
            )
        }
    }

    public var connectionState: AgentConnectionState { transport.connectionState }
    public var hasActiveTurn: Bool { activeTurn != nil }
    public var agentModifiedPaths: Set<String> {
        Set(appliedChanges.compactMap { record in
            guard record.status == .applied || record.status == .revertPrepared else { return nil }
            if !record.changeHunks.isEmpty, record.changeHunks.allSatisfy(\.isReverted) { return nil }
            return record.relativePath
        })
    }
    public var turnFileChanges: [ConversationTurnFileChanges] {
        guard let index = selectedConversationIndex,
              let selectedRemoteThreadID = document.conversations[index].remoteThreadID else {
            return []
        }
        let selectedRecords = appliedChanges.filter { record in
            record.threadID == selectedRemoteThreadID && record.status != .prepared
        }
        return Dictionary(grouping: selectedRecords) { record in
            "\(record.threadID):\(record.turnID)"
        }
        .values
        .map { records in
            let sorted = records.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt < rhs.createdAt
            }
            return ConversationTurnFileChanges(
                threadID: sorted[0].threadID,
                turnID: sorted[0].turnID,
                records: sorted
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.records.last?.createdAt ?? .distantPast
            let rhsDate = rhs.records.last?.createdAt ?? .distantPast
            if lhsDate == rhsDate { return lhs.id < rhs.id }
            return lhsDate > rhsDate
        }
    }

    public var fileChangeCapability: ConversationFileChangeCapability {
        guard fileChangeService != nil else {
            return .unavailable(message: "The audited project file service is unavailable.")
        }
        guard let index = selectedConversationIndex else {
            return .unavailable(message: "Start or select a chat first.")
        }
        let conversation = document.conversations[index]
        if conversation.remoteThreadID == nil || conversation.dynamicToolsVersion == Self.dynamicToolsVersion {
            return .available
        }
        return .requiresNewChat
    }

    public var canSend: Bool {
        guard case .connected = connectionState else { return false }
        guard !isShutdown, !isMutating, activeTurn == nil, !queueOperationInFlight, selectedThreadID != nil else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard draft.utf8.count <= AgentConversationStore.maximumTextBytes else { return false }
        if let selectedModelID {
            return models.contains(where: { $0.id == selectedModelID })
        }
        return true
    }

    /// The composer can queue a valid draft while a live response is in progress.
    public var canQueue: Bool {
        guard case .connected = connectionState,
              !isShutdown,
              activeTurn != nil,
              selectedConversationIndex != nil,
              !isMutating,
              !queueOperationInFlight else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf8.count <= AgentConversationStore.maximumTextBytes
    }

    /// Steering is only legal after the app-server has bound the active turn identity.
    public var canSteer: Bool {
        guard case .connected = connectionState,
              !isShutdown,
              let active = activeTurn,
              !active.stopRequested,
              active.remoteThreadID != nil,
              active.remoteTurnID != nil,
              queuedMessageInFlightID == nil,
              !isMutating,
              !queueOperationInFlight,
              let index = conversationIndex(id: active.conversationID),
              document.conversations[index].messages.count < AgentConversationStore.maximumMessagesPerConversation else { return false }
        return selectedThreadID == active.conversationID && transport.selectedProfileID == active.profileID
    }

    private let projectURL: URL
    private let projectPath: String
    private let transport: AgentConversationTransport
    private let store: AgentConversationStore
    private let fileChangeService: AgentFileChangeService?
    private let promptStore: AgentPromptStore?
    private let planStore: ProjectPlanStore?
    private var document: StoredConversationDocument
    private var observers: [UUID: Observer] = [:]
    private var connectionObserverID: UUID?
    private var runtimeObserverID: UUID?
    private var dynamicToolHandlerID: UUID?
    private var activeTurn: ActiveConversationTurn?
    private var retainedTelemetryTurn: RetainedConversationTurn?
    private var pendingFileToolInvocationID: UUID?
    private var generation = 0
    private var loaded = false
    private var observedProfileID: UUID?
    private var draftSaveTask: Task<Void, Never>?
    private var isMutating = false
    private var isShutdown = false
    private var queueOperationInFlight = false
    private var selectedPlanSnapshot: (id: String, hash: String)?

    private static let dynamicToolsVersion = 1

    public convenience init(
        projectURL: URL,
        connectionManager: AgentConnectionManager
    ) {
        self.init(
            projectURL: projectURL,
            transport: LiveAgentConversationTransport(manager: connectionManager),
            storageURL: nil
        )
    }

    init(
        projectURL: URL,
        transport: AgentConversationTransport,
        storageURL: URL? = nil
    ) {
        let canonical = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.projectURL = canonical
        projectPath = canonical.path
        self.transport = transport
        store = AgentConversationStore(projectURL: canonical, storageURL: storageURL)
        fileChangeService = try? AgentFileChangeService(projectURL: canonical)
        promptStore = try? AgentPromptStore(projectURL: canonical)
        planStore = try? ProjectPlanStore(projectURL: canonical)
        document = StoredConversationDocument(
            version: 1,
            projectPath: canonical.path,
            selectedThreadIDs: [:],
            conversations: []
        )
        observedProfileID = transport.selectedProfileID
        connectionObserverID = transport.addConnectionObserver { [weak self] in
            self?.handleConnectionChange()
        }
        runtimeObserverID = transport.addRuntimeObserver { [weak self] event in
            self?.handleRuntimeEvent(event)
        }
        dynamicToolHandlerID = transport.setDynamicToolHandler { [weak self] request in
            guard let self else {
                return .rejected("The workspace closed before this file change could be reviewed.")
            }
            return await self.handleDynamicTool(request)
        }
    }

    isolated deinit {
        draftSaveTask?.cancel()
        if let connectionObserverID { transport.removeConnectionObserver(connectionObserverID) }
        if let runtimeObserverID { transport.removeRuntimeObserver(runtimeObserverID) }
        if let dynamicToolHandlerID { transport.removeDynamicToolHandler(dynamicToolHandlerID) }
        if loaded {
            let store = store
            let snapshot = document
            Task { try? await store.save(snapshot) }
        }
    }

    @discardableResult
    public func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func load() async throws {
        clearLiveProgress()
        guard !loaded else { return }
        guard !isMutating else {
            throw AgentConversationError.unavailable("Conversation storage is busy.")
        }
        isMutating = true
        defer { isMutating = false }
        let loadedDocument = try await store.load()
        document = loadedDocument
        var repairedGeneratedTitles = false
        for index in document.conversations.indices where document.conversations[index].title.contains("<fs_code_attachments>") {
            guard let firstUserMessage = document.conversations[index].messages.first(where: { $0.role == .user }) else { continue }
            let repaired = Self.title(from: firstUserMessage.text)
            guard !repaired.isEmpty else { continue }
            document.conversations[index].title = repaired
            repairedGeneratedTitles = true
        }
        // Saved work is deliberately inert after reopening: an earlier turn may have ended while
        // the application was closed, so only an explicit user resume can send it.
        for index in document.conversations.indices where !(document.conversations[index].queuedMessages ?? []).isEmpty {
            document.conversations[index].queueIsPaused = true
            document.conversations[index].queueError = "Queue paused after reopening this project. Resume it when ready."
        }
        if let fileChangeService {
            appliedChanges = (try? await fileChangeService.history()) ?? []
        }
        loaded = true
        if repairedGeneratedTitles { try? await store.save(document) }
        refreshVisibleConversation()
        notifyObservers()
    }

    /// Creates the first local chat for the selected connected profile when needed.
    /// Repeated or overlapping calls are safe and never replace an existing selection.
    public func ensureInitialThread() async throws -> ConversationThread? {
        guard loaded, case .connected = connectionState, transport.selectedProfileID != nil else {
            return nil
        }
        if let selectedThreadID,
           let existing = threads.first(where: { $0.id == selectedThreadID }) {
            return existing
        }
        guard !isMutating, activeTurn == nil else { return nil }
        return try await newThread()
    }

    public func newThread() async throws -> ConversationThread {
        try ensureLoaded()
        selectedPlanSnapshot = nil
        guard !isMutating else {
            throw AgentConversationError.unavailable("Conversation storage is busy.")
        }
        guard activeTurn == nil else {
            throw AgentConversationError.unavailable("Stop the current response before starting another chat.")
        }
        guard let profileID = transport.selectedProfileID else {
            throw AgentConversationError.noSelectedProfile
        }
        guard document.conversations.count < AgentConversationStore.maximumConversations else {
            throw AgentConversationError.storageLimit
        }

        isMutating = true
        defer { isMutating = false }
        draftSaveTask?.cancel()
        let now = Date()
        let selectedModel = transport.profileSelectedModelID
            ?? models.first(where: \.isDefault)?.id
            ?? models.first?.id
        let selectedOption = models.first(where: { $0.id == selectedModel })
        let conversation = StoredConversation(
            id: UUID(),
            profileID: profileID,
            remoteThreadID: nil,
            lastRemoteTurnID: nil,
            dynamicToolsVersion: nil,
            title: "New Chat",
            createdAt: now,
            updatedAt: now,
            modelID: selectedModel,
            reasoningEffort: selectedOption?.defaultEffort,
            draft: "",
            messages: [],
            inputContextUsage: nil,
            activitySummaries: nil,
            queuedMessages: nil,
            queueIsPaused: nil,
            queueError: nil
            ,mode: .build
        )
        let previousSelection = document.selectedThreadIDs[profileID.uuidString]
        document.conversations.append(conversation)
        document.selectedThreadIDs[profileID.uuidString] = conversation.id
        do {
            try await persist()
        } catch {
            document.conversations.removeAll { $0.id == conversation.id }
            document.selectedThreadIDs[profileID.uuidString] = previousSelection
            throw error
        }
        refreshVisibleConversation()
        notifyObservers()
        return ConversationThread(id: conversation.id, title: conversation.title, updatedAt: now)
    }

    public func setMode(_ newMode: AgentMode) async throws {
        try ensureLoaded()
        guard activeTurn == nil, !queueOperationInFlight else {
            throw AgentConversationError.unavailable("Mode cannot change during a response or queued work.")
        }
        guard let index = selectedConversationIndex else { throw AgentConversationError.noSelectedConversation }
        guard (document.conversations[index].queuedMessages ?? []).isEmpty else {
            throw AgentConversationError.unavailable("Mode cannot change while messages are queued.")
        }
        document.conversations[index].mode = newMode
        if newMode != .build { selectedPlanSnapshot = nil }
        mode = newMode
        try await persist()
        notifyObservers()
    }

    /// Starts an actual Build turn only after the host-side approval snapshot still matches.
    public func executePlan(planID: String) async throws {
        try ensureLoaded()
        guard case .connected = connectionState,
              selectedConversationIndex != nil,
              activeTurn == nil, queuedMessages.isEmpty, let planStore else {
            throw AgentConversationError.unavailable("Finish the current chat work before executing a plan.")
        }
        let plan = try planStore.read(planID: planID)
        guard try planStore.isApproved(planID: planID) else {
            throw AgentConversationError.unavailable("This plan is not currently approved, or it changed after approval.")
        }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConversationError.unavailable("Save or clear the current draft before executing a plan.")
        }
        try await setMode(.build)
        selectedPlanSnapshot = (planID, plan.metadata.contentHash)
        guard let index = selectedConversationIndex else { throw AgentConversationError.noSelectedConversation }
        document.conversations[index].draft = "Implement the approved plan at .fs/plans/\(planID).md."
        try await persist()
        refreshVisibleConversation()
        notifyObservers()
        await send()
    }

    public func selectThread(id: UUID?) async {
        guard loaded, activeTurn == nil, !isMutating else { return }
        selectedPlanSnapshot = nil
        clearLiveProgress()
        isMutating = true
        defer { isMutating = false }
        draftSaveTask?.cancel()
        do {
            try await persist()
        } catch {
            fail(error)
            return
        }
        guard let profileID = transport.selectedProfileID else {
            selectedThreadID = nil
            refreshVisibleConversation()
            notifyObservers()
            return
        }
        if let id,
           !document.conversations.contains(where: { $0.id == id && $0.profileID == profileID }) {
            return
        }
        document.selectedThreadIDs[profileID.uuidString] = id
        do {
            try await persist()
            refreshVisibleConversation()
            notifyObservers()
        } catch {
            fail(error)
        }
    }

    public func updateDraft(_ text: String) {
        guard loaded, !isMutating, let index = selectedConversationIndex else { return }
        document.conversations[index].draft = text
        draft = document.conversations[index].draft
        if text.utf8.count > AgentConversationStore.maximumTextBytes {
            activity = .failed(message: "The message is too large to save or send. Shorten it to 512 KiB or less.")
            draftSaveTask?.cancel()
        } else {
            if case .failed(let message) = activity, message.contains("512 KiB") {
                activity = .idle
            }
            scheduleDraftPersistence()
        }
        notifyObservers()
    }

    public func flush() async throws {
        try ensureLoaded()
        draftSaveTask?.cancel()
        try await persist()
    }

    /// Flushes local history, detaches observers, and releases this workspace's runtime client.
    /// Call this from the workspace teardown path before releasing the manager.
    public func shutdown() async throws {
        guard !isShutdown else { return }
        // Prevent independently scheduled queue drains from beginning while teardown awaits the
        // active interruption and final persistence.
        isShutdown = true
        if activeTurn != nil { await stop() }
        generation += 1
        activeTurn = nil
        await cancelPendingFileChanges(reinstallHandler: false)
        draftSaveTask?.cancel()
        var persistenceError: Error?
        if loaded {
            do {
                try await persist()
            } catch {
                persistenceError = error
            }
        }
        if let connectionObserverID {
            transport.removeConnectionObserver(connectionObserverID)
            self.connectionObserverID = nil
        }
        if let runtimeObserverID {
            transport.removeRuntimeObserver(runtimeObserverID)
            self.runtimeObserverID = nil
        }
        await transport.shutdown()
        if let persistenceError { throw persistenceError }
    }

    /// Compatibility entry point for a proposal UI from earlier builds. Automatic tool edits do
    /// not publish proposals, so this only resolves an already visible legacy proposal.
    public func resolveFileChangeProposal(
        id: UUID,
        decision: ConversationFileChangeDecision
    ) async {
        guard let proposal = fileChangeProposals.first(where: { $0.id == id }),
              let identity = currentFileToolIdentity(for: proposal) else {
            return
        }
        if decision == .reject {
            if let fileChangeService { await fileChangeService.discard(proposal.id) }
            fileChangeProposals.removeAll { $0.id == proposal.id }
            notifyObservers()
        } else {
            _ = await applyStagedFileChange(proposal, identity: identity)
        }
    }

    public func revertAppliedChange(id: UUID) async throws {
        guard let service = fileChangeService else {
            throw AgentConversationError.unavailable("The audited project file service is unavailable.")
        }
        guard let record = appliedChanges.first(where: { $0.id == id }) else {
            throw AgentFileChangeError.recordUnavailable
        }
        guard let authorizeFileMutation else {
            throw AgentConversationError.unavailable(
                "FS Code cannot modify a project file until the workspace confirms that no unsaved editor buffer would be overwritten."
            )
        }
        guard await authorizeFileMutation(record.relativePath, .revert) else {
            throw AgentConversationError.unavailable(
                "Revert was blocked because the file has unsaved edits or the workspace is unavailable."
            )
        }
        guard !Task.isCancelled, !isShutdown else { throw CancellationError() }
        let reverted = try await service.revert(recordID: id)
        appliedChanges = try await service.history()
        didCompleteFileMutation?(
            ConversationFileMutationResult(
                id: reverted.id,
                relativePath: reverted.relativePath,
                operation: .revert
            )
        )
        notifyObservers()
    }

    public func revertChangeHunk(recordID: UUID, hunkID: String) async throws {
        guard let service = fileChangeService else {
            throw AgentConversationError.unavailable("The audited project file service is unavailable.")
        }
        guard let record = appliedChanges.first(where: { $0.id == recordID }),
              record.changeHunks.contains(where: { $0.id == hunkID }) else {
            throw AgentFileChangeError.recordUnavailable
        }
        guard let authorizeFileMutation else {
            throw AgentConversationError.unavailable(
                "FS Code cannot modify a project file until the workspace confirms that no unsaved editor buffer would be overwritten."
            )
        }
        guard await authorizeFileMutation(record.relativePath, .revert) else {
            throw AgentConversationError.unavailable(
                "Revert was blocked because the file has unsaved edits or the workspace is unavailable."
            )
        }
        guard !Task.isCancelled, !isShutdown else { throw CancellationError() }
        let reverted = try await service.revertHunk(recordID: recordID, hunkID: hunkID)
        appliedChanges = try await service.history()
        didCompleteFileMutation?(
            ConversationFileMutationResult(
                id: reverted.id,
                relativePath: reverted.relativePath,
                operation: .revert,
                hunkID: hunkID
            )
        )
        notifyObservers()
    }

    /// Restores the selected chat to immediately before `turnID`. The file service validates
    /// the complete audited chain; the workspace must approve every affected path before it
    /// begins any write so one dirty editor buffer cannot produce a partial restore.
    public func restorePoint(turnID: String) async throws {
        try ensureLoaded()
        guard !isShutdown, activeTurn == nil, pendingFileToolInvocationID == nil, !isMutating else {
            throw AgentConversationError.unavailable("Stop the current response before restoring a chat checkpoint.")
        }
        guard let service = fileChangeService else {
            throw AgentConversationError.unavailable("The audited project file service is unavailable.")
        }
        guard let index = selectedConversationIndex,
              let threadID = document.conversations[index].remoteThreadID else {
            throw AgentConversationError.noSelectedConversation
        }
        guard let authorizeFileMutation else {
            throw AgentConversationError.unavailable(
                "FS Code cannot restore a checkpoint until the workspace confirms that no unsaved editor buffer would be overwritten."
            )
        }

        isMutating = true
        defer { isMutating = false }
        let paths = try await service.restorePointPaths(threadID: threadID, turnID: turnID)
        guard !paths.isEmpty else { throw AgentFileChangeError.restoreUnavailable }
        for path in paths {
            guard await authorizeFileMutation(path, .revert) else {
                throw AgentConversationError.unavailable(
                    "Restore was blocked because at least one affected file has unsaved edits or the workspace is unavailable. Nothing was written."
                )
            }
        }
        guard !Task.isCancelled, !isShutdown, activeTurn == nil,
              selectedConversationIndex == index,
              document.conversations[index].remoteThreadID == threadID else {
            throw CancellationError()
        }
        let restored = try await service.restorePoint(threadID: threadID, turnID: turnID)
        appliedChanges = try await service.history()
        for path in paths {
            if let record = restored.first(where: { $0.relativePath == path }) {
                didCompleteFileMutation?(
                    ConversationFileMutationResult(id: record.id, relativePath: path, operation: .revert)
                )
            }
        }
        notifyObservers()
    }

    public func selectModel(id: String?) async throws {
        try ensureLoaded()
        guard !isMutating else {
            throw AgentConversationError.unavailable("Conversation storage is busy.")
        }
        guard activeTurn == nil else {
            throw AgentConversationError.unavailable("The model cannot change during a response.")
        }
        guard id == nil || models.contains(where: { $0.id == id }) else {
            throw AgentConversationError.unavailable("That model is no longer available.")
        }
        guard let index = selectedConversationIndex else {
            throw AgentConversationError.noSelectedConversation
        }
        isMutating = true
        defer { isMutating = false }
        let previousModel = document.conversations[index].modelID
        let previousEffort = document.conversations[index].reasoningEffort
        let previousUsage = document.conversations[index].inputContextUsage
        let previousRetainedTelemetryTurn = retainedTelemetryTurn
        document.conversations[index].modelID = id
        document.conversations[index].inputContextUsage = nil
        retainedTelemetryTurn = nil
        lastRequestInputContext = nil
        if let id, let option = models.first(where: { $0.id == id }) {
            if let effort = document.conversations[index].reasoningEffort,
               !option.supportedEfforts.contains(effort) {
                document.conversations[index].reasoningEffort = option.defaultEffort
            }
        } else {
            document.conversations[index].reasoningEffort = nil
        }
        do {
            try await persist()
        } catch {
            document.conversations[index].modelID = previousModel
            document.conversations[index].reasoningEffort = previousEffort
            document.conversations[index].inputContextUsage = previousUsage
            retainedTelemetryTurn = previousRetainedTelemetryTurn
            lastRequestInputContext = previousUsage
            throw error
        }
        refreshVisibleConversation()
        notifyObservers()
    }

    public func selectEffort(_ effort: ConversationReasoningEffort?) async throws {
        try ensureLoaded()
        guard !isMutating else {
            throw AgentConversationError.unavailable("Conversation storage is busy.")
        }
        guard activeTurn == nil else {
            throw AgentConversationError.unavailable("Reasoning effort cannot change during a response.")
        }
        guard let index = selectedConversationIndex else {
            throw AgentConversationError.noSelectedConversation
        }
        if let effort,
           let modelID = document.conversations[index].modelID,
           let option = models.first(where: { $0.id == modelID }),
           !option.supportedEfforts.contains(effort) {
            throw AgentConversationError.unavailable("That reasoning effort is not available for this model.")
        }
        isMutating = true
        defer { isMutating = false }
        let previous = document.conversations[index].reasoningEffort
        document.conversations[index].reasoningEffort = effort
        do {
            try await persist()
        } catch {
            document.conversations[index].reasoningEffort = previous
            throw error
        }
        refreshVisibleConversation()
        notifyObservers()
    }

    public func send() async {
        guard !queueOperationInFlight else { return }
        if activeTurn != nil {
            await enqueueDraft()
            return
        }
        await startTurn(queuedMessage: nil)
    }

    private func startTurn(queuedMessage: ConversationQueuedMessage?) async {
        var startedGeneration: Int?
        var queuedOwner: (conversationID: UUID, profileID: UUID)?
        do {
            try ensureLoaded()
            guard !isShutdown else { return }
            guard !isMutating else {
                throw AgentConversationError.unavailable("Conversation storage is busy.")
            }
            // Queue draining owns the operation lock while it invokes this internal method.
            // Public sends are rejected above, but the FIFO head must be allowed through.
            guard queuedMessage != nil || !queueOperationInFlight else { return }
            guard activeTurn == nil else { return }
            guard case .connected = connectionState else {
                throw AgentConversationError.unavailable("Connect an account before sending a message.")
            }
            guard let profileID = transport.selectedProfileID else {
                throw AgentConversationError.noSelectedProfile
            }
            guard let index = selectedConversationIndex,
                  document.conversations[index].profileID == profileID else {
                throw AgentConversationError.noSelectedConversation
            }
            let text = queuedMessage?.text ?? document.conversations[index].draft
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard text.utf8.count <= AgentConversationStore.maximumTextBytes else {
                fail(AgentConversationError.unavailable(
                    "The message is too large to save or send. Shorten it to 512 KiB or less."
                ))
                return
            }
            guard document.conversations[index].messages.count < AgentConversationStore.maximumMessagesPerConversation else {
                throw AgentConversationError.storageLimit
            }

            if let queuedMessage,
               !(document.conversations[index].queuedMessages ?? []).contains(where: { $0.id == queuedMessage.id }) {
                return
            }

            draftSaveTask?.cancel()
            generation += 1
            let turnGeneration = generation
            let conversationID = document.conversations[index].id
            startedGeneration = turnGeneration
            if queuedMessage != nil { queuedOwner = (conversationID, profileID) }
            let userMessage = ConversationMessage(id: queuedMessage?.id ?? UUID(), role: .user, text: text)
            if queuedMessage == nil { document.conversations[index].messages.append(userMessage) }
            if queuedMessage == nil { document.conversations[index].draft = "" }
            document.conversations[index].updatedAt = Date()
            if document.conversations[index].title == "New Chat" {
                document.conversations[index].title = Self.title(from: text)
            }
            activeTurn = ActiveConversationTurn(
                generation: turnGeneration,
                conversationID: conversationID,
                profileID: profileID,
                userMessageID: userMessage.id
            )
            retainedTelemetryTurn = nil
            activity = .starting
            refreshVisibleConversation()
            notifyObservers()
            // A queued request is already durable. It becomes transcript only after Codex
            // acknowledges turn/start, so a reload can never silently replay it.
            if queuedMessage == nil { try await persist() }
            guard isCurrent(turnGeneration, profileID: profileID) else { return }

            let isStartingThread = document.conversations[index].remoteThreadID == nil
            let threadResponse: AgentConnectionRuntimeResponse
            if let remoteThreadID = document.conversations[index].remoteThreadID {
                var parameters = try threadParameters(
                    remoteThreadID: remoteThreadID,
                    modelID: document.conversations[index].modelID,
                    fileEditsEnabled: document.conversations[index].dynamicToolsVersion == Self.dynamicToolsVersion
                )
                parameters["excludeTurns"] = true
                threadResponse = try await transport.request(
                    method: "thread/resume",
                    params: parameters,
                    expectedProfileID: profileID,
                    expectedSessionID: nil
                )
            } else {
                threadResponse = try await transport.request(
                    method: "thread/start",
                    params: try threadParameters(
                        remoteThreadID: nil,
                        modelID: document.conversations[index].modelID,
                        fileEditsEnabled: true
                    ),
                    expectedProfileID: profileID,
                    expectedSessionID: nil
                )
            }
            guard isCurrent(turnGeneration, profileID: profileID) else { return }
            guard threadResponse.profileID == profileID,
                  let thread = threadResponse.result["thread"] as? [String: Any],
                  let remoteThreadID = thread["id"] as? String,
                  !remoteThreadID.isEmpty else {
                throw AgentConversationError.unavailable("Codex returned an invalid chat session.")
            }
            if let existing = document.conversations[index].remoteThreadID, existing != remoteThreadID {
                throw AgentConversationError.unavailable("Codex resumed a different chat session.")
            }
            let instructionSources = threadResponse.result["instructionSources"] as? [Any] ?? []
            guard instructionSources.isEmpty else {
                throw AgentConversationError.unexpectedInstructionSources
            }
            let nativeHostTools = threadResponse.result["executionPolicy"] as? String == "hostTools"
            let confirmedPolicy: Bool
            if nativeHostTools {
                confirmedPolicy = (threadResponse.result["sandbox"] as? [String: Any])?["networkAccess"] as? Bool != true
            } else {
                confirmedPolicy = (threadResponse.result["sandbox"] as? [String: Any])?["type"] as? String == "readOnly"
                    && (threadResponse.result["sandbox"] as? [String: Any])?["networkAccess"] as? Bool != true
            }
            guard confirmedPolicy else {
                throw AgentConversationError.unavailable(
                    "The connection did not confirm its restricted execution policy. The message was not sent."
                )
            }
            document.conversations[index].remoteThreadID = remoteThreadID
            if isStartingThread {
                document.conversations[index].dynamicToolsVersion = Self.dynamicToolsVersion
            }
            activeTurn?.sessionID = threadResponse.sessionID
            activeTurn?.remoteThreadID = remoteThreadID
            if queuedMessage == nil { try await persist() }
            guard isCurrent(turnGeneration, profileID: profileID),
                  activeTurn?.sessionID == threadResponse.sessionID else { return }

            let clientUserMessageID = userMessage.id.uuidString
            var turnParams: [String: Any] = [
                "threadId": remoteThreadID,
                "input": [["type": "text", "text": text]],
                "cwd": projectPath,
                "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                "clientUserMessageId": clientUserMessageID
            ]
            if let modelID = document.conversations[index].modelID { turnParams["model"] = modelID }
            if let effort = document.conversations[index].reasoningEffort { turnParams["effort"] = effort.rawValue }

            let turnResponse = try await transport.request(
                method: "turn/start",
                params: turnParams,
                expectedProfileID: profileID,
                expectedSessionID: threadResponse.sessionID
            )
            guard isCurrent(turnGeneration, profileID: profileID) else { return }
            guard turnResponse.sessionID == threadResponse.sessionID,
                  let turn = turnResponse.result["turn"] as? [String: Any],
                  let remoteTurnID = turn["id"] as? String,
                  !remoteTurnID.isEmpty else {
                throw AgentConversationError.unavailable("Codex returned an invalid turn identifier.")
            }
            if let boundTurnID = activeTurn?.remoteTurnID, boundTurnID != remoteTurnID {
                throw AgentConversationError.unavailable("Codex returned a different turn than the active tool request.")
            }
            if let queuedMessage {
                guard let queuedIndex = (document.conversations[index].queuedMessages ?? []).firstIndex(where: {
                    $0.id == queuedMessage.id
                }) else {
                    throw AgentConversationError.unavailable("The queued message changed before Codex accepted it.")
                }
                document.conversations[index].queuedMessages?.remove(at: queuedIndex)
                if document.conversations[index].queuedMessages?.isEmpty == true {
                    document.conversations[index].queuedMessages = nil
                }
                document.conversations[index].messages.append(userMessage)
                queuedMessageInFlightID = nil
                try await persist()
                refreshVisibleConversation()
            }
            bindTurn(remoteTurnID, generation: turnGeneration)
            if activeTurn != nil {
                activity = activeTurn?.stopRequested == true ? .stopping : .responding(progress: "Thinking…")
                notifyObservers()
                await interruptIfNeeded()
            }
        } catch {
            if queuedMessage != nil {
                if let active = activeTurn, active.generation == startedGeneration {
                    finishActivities(for: active, status: "failed")
                    activeTurn = nil
                    cancelPendingFileChangesSoon(reinstallHandler: true)
                }
                activity = .failed(message: Self.safe(error))
                if let queuedOwner {
                    pauseQueue(conversationID: queuedOwner.conversationID, profileID: queuedOwner.profileID, message: Self.safe(error))
                } else {
                    pauseQueue(after: error)
                }
            } else {
                failActiveTurn(error)
            }
        }
    }

    private func enqueueDraft() async {
        guard canQueue, !queueOperationInFlight, let index = selectedConversationIndex else { return }
        let owner = (document.conversations[index].id, document.conversations[index].profileID)
        queueOperationInFlight = true
        defer {
            queueOperationInFlight = false
            notifyObservers()
            Task { @MainActor [weak self] in
                await self?.drainQueueIfPossible(conversationID: owner.0, profileID: owner.1)
            }
        }
        let capturedDraft = document.conversations[index].draft
        let message = ConversationQueuedMessage(text: capturedDraft)
        guard (document.conversations[index].queuedMessages ?? []).count < AgentConversationStore.maximumMessagesPerConversation else {
            queueError = "The queue has reached the local message limit."
            notifyObservers()
            return
        }
        document.conversations[index].queuedMessages = (document.conversations[index].queuedMessages ?? []) + [message]
        do {
            // Save the queue and a cleared captured draft atomically, without overwriting text
            // typed while the save was in flight.
            var snapshot = document
            snapshot.conversations[index].draft = ""
            try await persist(snapshot)
            if document.conversations[index].draft == capturedDraft {
                document.conversations[index].draft = ""
            }
            queueError = nil
            refreshVisibleConversation()
            notifyObservers()
        } catch {
            document.conversations[index].queuedMessages?.removeAll { $0.id == message.id }
            pauseQueue(conversationID: owner.0, profileID: owner.1, message: Self.safe(error))
        }
    }

    public func removeQueuedMessage(id: UUID) async throws {
        try ensureLoaded()
        guard queuedMessageInFlightID != id, !queueOperationInFlight,
              let index = selectedConversationIndex,
              let queuedIndex = (document.conversations[index].queuedMessages ?? []).firstIndex(where: { $0.id == id }) else {
            throw AgentConversationError.unavailable("That queued message is not available.")
        }
        queueOperationInFlight = true
        defer {
            queueOperationInFlight = false
            notifyObservers()
        }
        let message = document.conversations[index].queuedMessages![queuedIndex]
        document.conversations[index].queuedMessages!.remove(at: queuedIndex)
        if document.conversations[index].queuedMessages!.isEmpty { document.conversations[index].queuedMessages = nil }
        do {
            try await persist()
            refreshVisibleConversation()
            notifyObservers()
        } catch {
            document.conversations[index].queuedMessages = document.conversations[index].queuedMessages ?? []
            document.conversations[index].queuedMessages!.insert(message, at: queuedIndex)
            throw error
        }
    }

    public func steerQueuedMessage(id: UUID) async {
        guard canSteer, !queueOperationInFlight,
              let active = activeTurn,
              let threadID = active.remoteThreadID,
              let turnID = active.remoteTurnID,
              let sessionID = active.sessionID,
              let index = conversationIndex(id: active.conversationID),
              let message = (document.conversations[index].queuedMessages ?? []).first(where: { $0.id == id }) else { return }
        queueOperationInFlight = true
        queuedMessageInFlightID = id
        notifyObservers()
        var accepted = false
        defer {
            queueOperationInFlight = false
            queuedMessageInFlightID = nil
            notifyObservers()
            if accepted {
                Task { @MainActor [weak self] in
                    await self?.drainQueueIfPossible(conversationID: active.conversationID, profileID: active.profileID)
                }
            }
        }
        do {
            let response = try await transport.request(
                method: "turn/steer",
                params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": message.text]],
                    "expectedTurnId": turnID,
                    "clientUserMessageId": message.id.uuidString
                ],
                expectedProfileID: active.profileID,
                expectedSessionID: sessionID
            )
            guard response.profileID == active.profileID,
                  response.sessionID == sessionID,
                  let resultTurnID = response.result["turnId"] as? String,
                  resultTurnID == turnID,
                  document.conversations[index].remoteThreadID == threadID else {
                throw AgentConversationError.unavailable("Codex did not confirm steering the active turn.")
            }
            if let current = activeTurn {
                guard current.generation == active.generation,
                      current.remoteThreadID == threadID,
                      current.remoteTurnID == turnID else {
                    throw AgentConversationError.unavailable("Codex changed the active turn before steering was confirmed.")
                }
            } else {
                guard document.conversations[index].lastRemoteTurnID == turnID else {
                    throw AgentConversationError.unavailable("Codex did not confirm the completed turn that was steered.")
                }
            }
            guard let queuedIndex = (document.conversations[index].queuedMessages ?? []).firstIndex(where: { $0.id == id }) else { return }
            document.conversations[index].queuedMessages!.remove(at: queuedIndex)
            if document.conversations[index].queuedMessages!.isEmpty { document.conversations[index].queuedMessages = nil }
            document.conversations[index].messages.append(ConversationMessage(id: message.id, role: .user, text: message.text))
            document.conversations[index].updatedAt = Date()
            try await persist()
            queueError = nil
            refreshVisibleConversation()
            accepted = true
        } catch {
            pauseQueue(conversationID: active.conversationID, profileID: active.profileID, message: Self.safe(error))
        }
    }

    public func resumeQueue() async {
        guard loaded, !isShutdown, !queueOperationInFlight, let index = selectedConversationIndex else { return }
        let owner = (document.conversations[index].id, document.conversations[index].profileID)
        document.conversations[index].queueIsPaused = false
        document.conversations[index].queueError = nil
        queueIsPaused = false
        queueError = nil
        do {
            try await persist()
            await drainQueueIfPossible(conversationID: owner.0, profileID: owner.1)
        } catch {
            pauseQueue(conversationID: owner.0, profileID: owner.1, message: Self.safe(error))
        }
        refreshVisibleConversation()
        notifyObservers()
    }

    public func stop() async {
        guard var active = activeTurn else { return }
        clearLiveProgress()
        active.stopRequested = true
        activeTurn = active
        activity = .stopping
        pauseQueue(message: "Queue paused because the current response was stopped.")
        await cancelPendingFileChanges(reinstallHandler: true)
        notifyObservers()
        await interruptIfNeeded()
    }

    private func threadParameters(
        remoteThreadID: String?,
        modelID: String?,
        fileEditsEnabled: Bool
    ) throws -> [String: Any] {
        let activeMode = selectedConversationIndex.map { document.conversations[$0].mode ?? .build } ?? .build
        guard let promptStore else {
            throw AgentConversationError.unavailable("Agent prompts are unavailable for this project.")
        }
        let profilePrompt = try promptStore.load().prompt(for: activeMode)
        let effectivePrompt = profilePrompt + "\n\nPROJECT CONTEXT\nProject root: \(projectPath)\nProject instructions are supplied separately by the host."
        var params: [String: Any] = [
            "cwd": projectPath,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "developerInstructions": effectivePrompt,
            "agentMode": activeMode.rawValue,
            "hostMetadata": "mode: \(activeMode.rawValue)\ntool budget: \(activeMode == .build ? 40 : activeMode == .plan ? 15 : 4)\nnetwork access: false" + (selectedPlanSnapshot.map { "\nselected plan: .fs/plans/\($0.id).md\nselected plan hash: \($0.hash)" } ?? ""),
            "config": [
                "project_doc_max_bytes": 0,
                "projects": [projectPath: ["trust_level": "untrusted"]]
            ]
        ]
        if let selectedPlanSnapshot { params["selectedPlanID"] = selectedPlanSnapshot.id }
        if let remoteThreadID { params["threadId"] = remoteThreadID }
        if let modelID { params["model"] = modelID }
        if let index = selectedConversationIndex {
            let activeUserID = activeTurn?.userMessageID
            let baseline = document.conversations[index].messages
                .filter { $0.id != activeUserID }
                .map { ["role": $0.role.rawValue, "text": $0.text] }
            params["localHistory"] = baseline
        }
        if remoteThreadID == nil && activeMode == .build {
            params["dynamicTools"] = [Self.fileEditToolSpecification]
        }
        return params
    }

    private static let fileEditToolSpecification: [String: Any] = [
        "type": "function",
        "name": "fs_edit_file",
        "description": "Apply one exact text replacement or create one absent UTF-8 text file through FS Code's audited writer. Report the relative path and changed line range after success.",
        "inputSchema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "relative_path": [
                    "type": "string",
                    "description": "Project-relative path to the text file."
                ],
                "old_text": [
                    "type": "string",
                    "description": "Exact unique text to replace. Use an empty string only to create an absent file."
                ],
                "new_text": [
                    "type": "string",
                    "description": "Complete replacement text, or complete contents for a new file."
                ]
            ],
            "required": ["relative_path", "old_text", "new_text"]
        ]
    ]

    private func handleDynamicTool(_ request: AgentDynamicToolRequest) async -> AgentDynamicToolResult {
        guard request.namespace == nil, request.toolName == "fs_edit_file" else {
            return .rejected("FS Code does not allow this host tool.")
        }
        guard mode == .build else { return .rejected("Editing files is unavailable outside Build mode.") }
        guard pendingFileToolInvocationID == nil else {
            return .rejected("Another file change is already being applied. Retry after it finishes.")
        }
        let invocationID = UUID()
        pendingFileToolInvocationID = invocationID
        defer {
            if pendingFileToolInvocationID == invocationID {
                pendingFileToolInvocationID = nil
            }
        }
        guard let service = fileChangeService else {
            return .rejected("The audited project file service is unavailable.")
        }
        guard let identity = bindAndValidateFileToolRequest(request) else {
            return .rejected("This file change belongs to a chat or account that is no longer active.")
        }
        guard let arguments = Self.fileEditArguments(request.arguments) else {
            return .rejected(
                "fs_edit_file requires only relative_path, old_text, and new_text string arguments."
            )
        }
        let plansRoot = projectURL.appendingPathComponent(".fs/plans", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = projectURL.appendingPathComponent(arguments.relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let plansPrefix = plansRoot.path.hasSuffix("/") ? plansRoot.path : plansRoot.path + "/"
        guard candidate.path != plansRoot.path, !candidate.path.hasPrefix(plansPrefix) else {
            return .rejected("Plan files are protected from generic file edits.")
        }

        let proposal: AgentFileChangeProposal
        do {
            proposal = try await service.stageEdit(
                relativePath: arguments.relativePath,
                oldText: arguments.oldText,
                newText: arguments.newText,
                threadID: request.threadID,
                turnID: request.turnID
            )
        } catch {
            return .rejected(Self.safe(error))
        }
        guard !Task.isCancelled,
              pendingFileToolInvocationID == invocationID,
              isCurrent(identity) else {
            await service.discard(proposal.id)
            return .rejected("The active chat changed before this file change could be applied.")
        }
        return await applyStagedFileChange(proposal, identity: identity)
    }

    private func applyStagedFileChange(
        _ proposal: AgentFileChangeProposal,
        identity: FileToolInvocationIdentity
    ) async -> AgentDynamicToolResult {
        guard let service = fileChangeService else {
            return .rejected("This file change proposal is no longer available.")
        }
        guard !Task.isCancelled, isCurrent(identity) else {
            await service.discard(proposal.id)
            return .rejected("The active chat changed before this file change was applied.")
        }
        guard let authorizeFileMutation else {
            await service.discard(proposal.id)
            return .rejected(
                "FS Code could not verify whether an editor has unsaved changes. Nothing was written."
            )
        }

        let authorized = await authorizeFileMutation(proposal.relativePath, .apply)
        guard authorized else {
            await service.discard(proposal.id)
            if isCurrent(identity) {
                activity = .responding(progress: "File change blocked by unsaved editor content.")
            }
            notifyObservers()
            return .rejected(
                "The change was blocked because the file has unsaved edits or the workspace is unavailable. Nothing was written."
            )
        }
        guard !Task.isCancelled, isCurrent(identity) else {
            await service.discard(proposal.id)
            return .rejected("The active chat changed before this file change was applied.")
        }

        do {
            // AgentFileChangeService rechecks the staged revision and current file hash in the
            // actor-isolated call immediately before its atomic write.
            let record = try await service.applyApproved(proposal)
            appliedChanges.removeAll { $0.id == record.id }
            appliedChanges.insert(record, at: 0)
            if isCurrent(identity) {
                activity = .responding(progress: "Applied file change: \(record.relativePath)")
            }
            didCompleteFileMutation?(
                ConversationFileMutationResult(
                    id: record.id,
                    relativePath: record.relativePath,
                    operation: .apply
                )
            )
            notifyObservers()
            let changedLines = record.changeHunks
                .map { hunk in
                    let count = max(1, hunk.afterText.split(separator: "\n", omittingEmptySubsequences: false).count)
                    return count == 1
                        ? "line \(hunk.newStartLine)"
                        : "lines \(hunk.newStartLine)-\(hunk.newStartLine + count - 1)"
                }
                .joined(separator: ", ")
            let location = changedLines.isEmpty ? record.relativePath : "\(record.relativePath) (\(changedLines))"
            return .accepted("Applied the change to \(location).")
        } catch {
            if isCurrent(identity) {
                activity = .responding(progress: "File change failed: \(Self.safe(error))")
            }
            notifyObservers()
            return .rejected("The change was not written: \(Self.safe(error))")
        }
    }

    private func bindAndValidateFileToolRequest(
        _ request: AgentDynamicToolRequest
    ) -> FileToolInvocationIdentity? {
        guard var active = activeTurn,
              !active.stopRequested,
              active.profileID == request.profileID,
              active.sessionID == request.sessionID,
              active.remoteThreadID == request.threadID,
              transport.selectedProfileID == request.profileID,
              selectedThreadID == active.conversationID,
              let conversationIndex = conversationIndex(id: active.conversationID),
              document.conversations[conversationIndex].dynamicToolsVersion == Self.dynamicToolsVersion else {
            return nil
        }
        if let remoteTurnID = active.remoteTurnID {
            guard remoteTurnID == request.turnID else { return nil }
        } else {
            // The app-server can coalesce a tool request with the turn/start response. The
            // request is already session/thread scoped, so bind its turn and verify the later
            // turn/start response returns the same identifier.
            active.remoteTurnID = request.turnID
            activeTurn = active
        }
        return FileToolInvocationIdentity(
            generation: active.generation,
            conversationID: active.conversationID,
            profileID: request.profileID,
            sessionID: request.sessionID,
            threadID: request.threadID,
            turnID: request.turnID
        )
    }

    private func currentFileToolIdentity(for proposal: AgentFileChangeProposal) -> FileToolInvocationIdentity? {
        guard let active = activeTurn,
              active.remoteThreadID == proposal.threadID,
              active.remoteTurnID == proposal.turnID,
              let sessionID = active.sessionID else { return nil }
        return FileToolInvocationIdentity(
            generation: active.generation,
            conversationID: active.conversationID,
            profileID: active.profileID,
            sessionID: sessionID,
            threadID: proposal.threadID,
            turnID: proposal.turnID
        )
    }

    private func isCurrent(_ identity: FileToolInvocationIdentity) -> Bool {
        guard let active = activeTurn else { return false }
        return active.generation == identity.generation
            && active.conversationID == identity.conversationID
            && active.profileID == identity.profileID
            && active.sessionID == identity.sessionID
            && active.remoteThreadID == identity.threadID
            && active.remoteTurnID == identity.turnID
            && !active.stopRequested
            && selectedThreadID == identity.conversationID
            && transport.selectedProfileID == identity.profileID
    }

    private static func fileEditArguments(
        _ value: AgentJSONValue
    ) -> (relativePath: String, oldText: String, newText: String)? {
        guard case .object(let object) = value,
              Set(object.keys) == Set(["relative_path", "old_text", "new_text"]),
              case .some(.string(let relativePath)) = object["relative_path"],
              case .some(.string(let oldText)) = object["old_text"],
              case .some(.string(let newText)) = object["new_text"] else {
            return nil
        }
        return (relativePath, oldText, newText)
    }

    private func installDynamicToolHandler() {
        guard dynamicToolHandlerID == nil, !isShutdown else { return }
        dynamicToolHandlerID = transport.setDynamicToolHandler { [weak self] request in
            guard let self else {
                return .rejected("The workspace closed before this file change could be reviewed.")
            }
            return await self.handleDynamicTool(request)
        }
    }

    private func cancelPendingFileChanges(reinstallHandler: Bool) async {
        if let dynamicToolHandlerID {
            transport.removeDynamicToolHandler(dynamicToolHandlerID)
            self.dynamicToolHandlerID = nil
        }
        pendingFileToolInvocationID = nil
        if let fileChangeService { await fileChangeService.discardAll() }
        fileChangeProposals = []
        if reinstallHandler { installDynamicToolHandler() }
    }

    private func cancelPendingFileChangesSoon(reinstallHandler: Bool) {
        if let dynamicToolHandlerID {
            transport.removeDynamicToolHandler(dynamicToolHandlerID)
            self.dynamicToolHandlerID = nil
        }
        pendingFileToolInvocationID = nil
        fileChangeProposals = []
        if reinstallHandler { installDynamicToolHandler() }
        if let fileChangeService {
            Task { await fileChangeService.discardAll() }
        }
    }

    private func bindTurn(_ remoteTurnID: String, generation: Int) {
        guard var active = activeTurn, active.generation == generation else { return }
        let buffered = active.bufferedEvents
        active.bufferedEvents.removeAll(keepingCapacity: false)
        active.remoteTurnID = remoteTurnID
        activeTurn = active
        if let conversationIndex = conversationIndex(id: active.conversationID),
           let messageIndex = document.conversations[conversationIndex].messages.firstIndex(where: {
               $0.id == active.userMessageID
           }) {
            document.conversations[conversationIndex].messages[messageIndex].turnID = remoteTurnID
            persistAfterEvent()
            refreshVisibleConversation()
        }
        bindActivitySummary(to: active)
        for event in buffered where event.turnID == remoteTurnID {
            apply(event, generation: generation)
        }
    }

    private func handleRuntimeEvent(_ event: AgentConnectionRuntimeEvent) {
        if event.method == "thread/tokenUsage/updated" {
            handleTokenUsage(event)
            return
        }
        guard var active = activeTurn,
              event.profileID == active.profileID,
              event.sessionID == active.sessionID,
              event.params["threadId"] as? String == active.remoteThreadID,
              let parsed = Self.parse(event) else { return }
        if let remoteTurnID = active.remoteTurnID {
            guard parsed.turnID == remoteTurnID else { return }
            apply(parsed, generation: active.generation)
        } else {
            guard active.bufferedEvents.count < 512 else {
                failActiveTurn(AgentConversationError.unavailable("Codex sent too many events before confirming the response."))
                return
            }
            active.bufferedEvents.append(parsed)
            activeTurn = active
        }
    }

    private func handleTokenUsage(_ event: AgentConnectionRuntimeEvent) {
        guard let threadID = event.params["threadId"] as? String,
              let turnID = event.params["turnId"] as? String,
              let usage = Self.inputContextUsage(from: event.params),
              let identity = telemetryIdentity(for: event, threadID: threadID, turnID: turnID),
              selectedThreadID == identity.conversationID,
              transport.selectedProfileID == identity.profileID,
              let index = conversationIndex(id: identity.conversationID) else {
            return
        }
        let modelID = document.conversations[index].modelID
        let modelBoundUsage = ConversationInputContextUsage(
            inputTokens: usage.inputTokens,
            modelContextWindow: usage.modelContextWindow,
            modelID: modelID
        )
        document.conversations[index].inputContextUsage = modelBoundUsage
        lastRequestInputContext = modelBoundUsage
        scheduleHistoryPersistence()
        notifyObservers()
    }

    private func telemetryIdentity(
        for event: AgentConnectionRuntimeEvent,
        threadID: String,
        turnID: String
    ) -> RetainedConversationTurn? {
        if let active = activeTurn,
           active.profileID == event.profileID,
           active.sessionID == event.sessionID,
           active.remoteThreadID == threadID,
           active.remoteTurnID == turnID {
            return RetainedConversationTurn(
                generation: active.generation,
                conversationID: active.conversationID,
                profileID: active.profileID,
                sessionID: event.sessionID,
                remoteThreadID: threadID,
                remoteTurnID: turnID
            )
        }
        guard let retained = retainedTelemetryTurn,
              retained.profileID == event.profileID,
              retained.sessionID == event.sessionID,
              retained.remoteThreadID == threadID,
              retained.remoteTurnID == turnID else {
            return nil
        }
        return retained
    }

    private static func parse(_ event: AgentConnectionRuntimeEvent) -> BufferedConversationEvent? {
        let params = event.params
        switch event.method {
        case "item/reasoning/summaryPartAdded":
            guard let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let summaryIndex = params["summaryIndex"] as? Int else { return nil }
            return .reasoningSummaryPart(turnID: turnID, itemID: itemID, summaryIndex: summaryIndex)
        case "item/reasoning/summaryTextDelta":
            guard let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let summaryIndex = params["summaryIndex"] as? Int,
                  let delta = params["delta"] as? String else { return nil }
            return .reasoningSummaryDelta(turnID: turnID, itemID: itemID, summaryIndex: summaryIndex, text: delta)
        case "item/agentMessage/delta":
            guard let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return nil }
            return .delta(turnID: turnID, itemID: itemID, text: delta)
        case "item/started":
            guard let turnID = params["turnId"] as? String,
                  let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String else { return nil }
            if type == "agentMessage",
               let itemID = item["id"] as? String,
               let rawPhase = item["phase"] as? String,
               let phase = ConversationMessagePhase(rawValue: rawPhase) {
                return .assistantPhase(turnID: turnID, itemID: itemID, phase: phase)
            }
            if let activity = activityMetadata(item: item, type: type) {
                return .activityStarted(
                    turnID: turnID,
                    itemID: activity.itemID,
                    phase: activity.phase,
                    operation: activity.operation
                )
            }
            let progress: String
            switch type {
            case "commandExecution": progress = "Reading project…"
            case "webSearch": progress = "Searching…"
            case "reasoning": progress = "Thinking…"
            default: progress = "Working…"
            }
            return .progress(turnID: turnID, text: progress)
        case "item/completed":
            guard let turnID = params["turnId"] as? String,
                  let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String else { return nil }
            if type == "agentMessage",
               let itemID = item["id"] as? String,
               let text = item["text"] as? String {
                return .finalMessage(
                    turnID: turnID,
                    itemID: itemID,
                    text: text,
                    phase: (item["phase"] as? String).flatMap(ConversationMessagePhase.init(rawValue:))
                )
            }
            if let activity = activityMetadata(item: item, type: type) {
                return .activityCompleted(
                    turnID: turnID,
                    itemID: activity.itemID,
                    phase: activity.phase,
                    operation: activity.operation,
                    status: item["status"] as? String,
                    output: activity.phase == .reasoning ? nil : boundedTelemetryOutput(from: item, phase: activity.phase)
                )
            }
            return nil
        case "error":
            guard params["willRetry"] as? Bool != true,
                  let turnID = params["turnId"] as? String,
                  let error = params["error"] as? [String: Any],
                  let message = error["message"] as? String else { return nil }
            return .failure(turnID: turnID, message: message)
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  let status = turn["status"] as? String else { return nil }
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            let finalMessage = Self.finalAgentText(in: turn)
            return .completed(turnID: turnID, status: status, error: error, finalMessage: finalMessage)
        default:
            return nil
        }
    }

    private static func inputContextUsage(from params: [String: Any]) -> (inputTokens: Int, modelContextWindow: Int)? {
        guard let tokenUsage = params["tokenUsage"] as? [String: Any],
              let last = tokenUsage["last"] as? [String: Any],
              let inputTokens = strictInteger(last["inputTokens"]),
              let modelContextWindow = strictInteger(tokenUsage["modelContextWindow"]),
              inputTokens >= 0,
              modelContextWindow > 0 else {
            return nil
        }
        return (inputTokens, modelContextWindow)
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            return Int(exactly: number.int64Value)
        case "C", "S", "I", "L", "Q":
            return Int(exactly: number.uint64Value)
        default:
            let double = number.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  double > Double(Int.min),
                  double < Double(Int.max) else {
                return nil
            }
            return Int(double)
        }
    }

    private static func activityMetadata(
        item: [String: Any],
        type: String
    ) -> (itemID: String, phase: ConversationActivityPhase, operation: String?)? {
        let phase: ConversationActivityPhase
        switch type {
        case "reasoning": phase = .reasoning
        case "commandExecution": phase = .command
        case "dynamicTool", "dynamicToolCall": phase = .dynamicTool
        case "mcpTool", "mcpToolCall": phase = .mcp
        default: return nil
        }
        guard let itemID = item["id"] as? String, !itemID.isEmpty else { return nil }
        let operation = ["command", "tool", "toolName", "name", "operation"]
            .compactMap { item[$0] as? String }
            .first
            .map { boundedTelemetryText($0, maximumBytes: 4_096) }
        return (itemID, phase, operation)
    }

    private static func boundedTelemetryOutput(
        from item: [String: Any],
        phase: ConversationActivityPhase
    ) -> String? {
        if let output = ["output", "aggregatedOutput"].compactMap({ item[$0] as? String }).first {
            return boundedTelemetryText(output, maximumBytes: 16_384)
        }
        if phase == .dynamicTool,
           let contentItems = item["contentItems"] as? [[String: Any]] {
            let text = contentItems.compactMap { content -> String? in
                guard content["type"] as? String == "inputText" else { return nil }
                return content["text"] as? String
            }.joined(separator: "\n")
            return text.isEmpty ? nil : boundedTelemetryText(text, maximumBytes: 16_384)
        }
        if phase == .mcp,
           let result = item["result"] as? [String: Any] {
            if let message = (result["error"] as? [String: Any])?["message"] as? String {
                return boundedTelemetryText(message, maximumBytes: 16_384)
            }
            let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return text.isEmpty ? nil : boundedTelemetryText(text, maximumBytes: 16_384)
        }
        return nil
    }

    private static func boundedTelemetryText(_ text: String, maximumBytes: Int) -> String {
        utf8Prefix(text, maximumBytes: maximumBytes)
    }

    private func bindActivitySummary(to active: ActiveConversationTurn) {
        guard let index = conversationIndex(id: active.conversationID),
              let remoteTurnID = active.remoteTurnID else { return }
        var summaries = document.conversations[index].activitySummaries ?? []
        if let summaryIndex = summaries.firstIndex(where: { $0.userMessageID == active.userMessageID }) {
            summaries[summaryIndex].remoteTurnID = remoteTurnID
        } else {
            summaries.append(ConversationTurnActivitySummary(
                userMessageID: active.userMessageID,
                remoteTurnID: remoteTurnID
            ))
        }
        document.conversations[index].activitySummaries = Array(summaries.suffix(64))
    }

    private func finishActivities(for active: ActiveConversationTurn, status: String) {
        updateActivitySummary(for: active) { summary in
            for index in summary.activities.indices where summary.activities[index].completedAt == nil {
                summary.activities[index].status = status
                summary.activities[index].completedAt = Date()
                if summary.activities[index].phase == .reasoning {
                    summary.activities[index].output = nil
                }
            }
        }
    }

    private func recordActivityStart(
        itemID: String,
        phase: ConversationActivityPhase,
        operation: String?,
        active: ActiveConversationTurn
    ) {
        updateActivitySummary(for: active) { summary in
            guard !summary.activities.contains(where: { $0.itemID == itemID }) else { return }
            summary.activities.append(ConversationTurnActivity(
                itemID: itemID,
                phase: phase,
                operation: operation,
                startedAt: Date()
            ))
        }
    }

    private func recordActivityCompletion(
        itemID: String,
        phase: ConversationActivityPhase,
        operation: String?,
        status: String?,
        output: String?,
        active: ActiveConversationTurn
    ) {
        updateActivitySummary(for: active) { summary in
            if let activityIndex = summary.activities.firstIndex(where: { $0.itemID == itemID }) {
                summary.activities[activityIndex].operation = operation ?? summary.activities[activityIndex].operation
                summary.activities[activityIndex].status = status.map { Self.boundedTelemetryText($0, maximumBytes: 4_096) }
                summary.activities[activityIndex].output = output
                summary.activities[activityIndex].completedAt = Date()
            } else {
                summary.activities.append(ConversationTurnActivity(
                    itemID: itemID,
                    phase: phase,
                    operation: operation,
                    status: status.map { Self.boundedTelemetryText($0, maximumBytes: 4_096) },
                    output: output,
                    startedAt: Date(),
                    completedAt: Date()
                ))
            }
        }
    }

    private func updateActivitySummary(
        for active: ActiveConversationTurn,
        update: (inout ConversationTurnActivitySummary) -> Void
    ) {
        guard let index = conversationIndex(id: active.conversationID) else { return }
        var summaries = document.conversations[index].activitySummaries ?? []
        if let summaryIndex = summaries.firstIndex(where: { $0.userMessageID == active.userMessageID }) {
            update(&summaries[summaryIndex])
        } else {
            var summary = ConversationTurnActivitySummary(
                userMessageID: active.userMessageID,
                remoteTurnID: active.remoteTurnID
            )
            update(&summary)
            summaries.append(summary)
        }
        document.conversations[index].activitySummaries = Array(summaries.suffix(64))
    }

    private func apply(_ event: BufferedConversationEvent, generation expected: Int) {
        guard var active = activeTurn, active.generation == expected else { return }
        switch event {
        case .reasoningSummaryPart(_, let itemID, let summaryIndex):
            guard !active.stopRequested, !active.hasFinalAnswerOutput else { return }
            guard liveProgressItemID != itemID || (liveProgressSummaryIndex ?? -1) <= summaryIndex else { return }
            liveProgressItemID = itemID
            liveProgressSummaryIndex = summaryIndex
            liveProgressText = nil
            liveProgressUserMessageID = nil
            activity = active.stopRequested ? .stopping : .responding(progress: "Thinking…")
            notifyObservers()
        case .reasoningSummaryDelta(_, let itemID, let summaryIndex, let text):
            guard !active.stopRequested, !active.hasFinalAnswerOutput else { return }
            if liveProgressItemID != itemID || liveProgressSummaryIndex != summaryIndex {
                guard liveProgressItemID != itemID || summaryIndex >= (liveProgressSummaryIndex ?? -1) else { return }
                liveProgressItemID = itemID
                liveProgressSummaryIndex = summaryIndex
                liveProgressText = nil
            }
            let combined = (liveProgressText ?? "") + text
            liveProgressText = Self.boundedTelemetryText(combined, maximumBytes: 4_096)
            liveProgressUserMessageID = active.userMessageID
            activity = active.stopRequested ? .stopping : .responding(progress: "Thinking…")
            notifyObservers()
        case .assistantPhase(_, let itemID, let phase):
            active.assistantMessagePhases[itemID] = phase
            if phase == .finalAnswer {
                clearLiveProgress()
                active.hasFinalAnswerOutput = true
            }
            activeTurn = active
            notifyObservers()
        case .delta(_, let itemID, let text):
            let phase = active.assistantMessagePhases[itemID]
            if phase == .finalAnswer {
                clearLiveProgress()
                active.hasFinalAnswerOutput = true
            } else {
                // Output replaces the currently rendered thinking summary, but commentary can
                // still be followed by a later reasoning section.
                clearLiveProgress()
            }
            appendAssistant(text, itemID: itemID, phase: phase, active: &active)
            activeTurn = active
            activity = active.stopRequested ? .stopping : .responding(progress: "Writing…")
            scheduleHistoryPersistence()
            notifyObservers()
        case .finalMessage(_, let itemID, let text, let eventPhase):
            let phase = eventPhase ?? active.assistantMessagePhases[itemID]
            if let phase { active.assistantMessagePhases[itemID] = phase }
            clearLiveProgress()
            if phase == .finalAnswer { active.hasFinalAnswerOutput = true }
            replaceAssistant(with: text, itemID: itemID, phase: phase, active: &active)
            activeTurn = active
            scheduleHistoryPersistence()
            notifyObservers()
        case .progress(_, let text):
            activity = active.stopRequested ? .stopping : .responding(progress: text)
            notifyObservers()
        case .activityStarted(_, let itemID, let phase, let operation):
            recordActivityStart(itemID: itemID, phase: phase, operation: operation, active: active)
            scheduleHistoryPersistence()
            refreshVisibleConversation()
            notifyObservers()
        case .activityCompleted(_, let itemID, let phase, let operation, let status, let output):
            recordActivityCompletion(
                itemID: itemID,
                phase: phase,
                operation: operation,
                status: status,
                output: output,
                active: active
            )
            scheduleHistoryPersistence()
            refreshVisibleConversation()
            notifyObservers()
        case .failure(_, let message):
            clearLiveProgress()
            finishActivities(for: active, status: "failed")
            activeTurn = nil
            cancelPendingFileChangesSoon(reinstallHandler: true)
            activity = .failed(message: message)
            pauseQueue(message: "Queue paused because the current response failed.")
            persistAfterEvent()
            notifyObservers()
        case .completed(let turnID, let status, let error, let finalMessage):
            clearLiveProgress()
            if let finalMessage {
                replaceAssistant(with: finalMessage.text, itemID: finalMessage.itemID, phase: active.assistantMessagePhases[finalMessage.itemID], active: &active)
            }
            finishActivities(for: active, status: status)
            if let index = conversationIndex(id: active.conversationID) {
                document.conversations[index].lastRemoteTurnID = turnID
                document.conversations[index].updatedAt = Date()
            }
            if let sessionID = active.sessionID,
               let remoteThreadID = active.remoteThreadID {
                retainedTelemetryTurn = RetainedConversationTurn(
                    generation: active.generation,
                    conversationID: active.conversationID,
                    profileID: active.profileID,
                    sessionID: sessionID,
                    remoteThreadID: remoteThreadID,
                    remoteTurnID: turnID
                )
            }
            activeTurn = nil
            cancelPendingFileChangesSoon(reinstallHandler: true)
            if active.outputTruncated {
                activity = .failed(message: "The response exceeded the 512 KiB local history limit and was truncated.")
            } else if status == "failed" {
                activity = .failed(message: error ?? "Codex could not complete the response.")
            } else {
                activity = .idle
            }
            refreshVisibleConversation()
            if status == "completed", !active.stopRequested, !active.outputTruncated {
                persistAfterEvent(drainConversation: (active.conversationID, active.profileID))
            } else {
                pauseQueue(message: "Queue paused because the current response did not complete successfully.")
                persistAfterEvent()
            }
            notifyObservers()
        }
    }

    private func appendAssistant(
        _ delta: String,
        itemID: String,
        phase: ConversationMessagePhase?,
        active: inout ActiveConversationTurn
    ) {
        guard let conversationIndex = conversationIndex(id: active.conversationID) else { return }
        if let messageID = active.assistantMessageIDs[itemID],
           let messageIndex = document.conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) {
            let combined = document.conversations[conversationIndex].messages[messageIndex].text + delta
            let output = Self.boundedOutput(combined)
            document.conversations[conversationIndex].messages[messageIndex].text = output.text
            if let phase { document.conversations[conversationIndex].messages[messageIndex].phase = phase }
            active.outputTruncated = active.outputTruncated || output.truncated
        } else if document.conversations[conversationIndex].messages.count < AgentConversationStore.maximumMessagesPerConversation {
            let output = Self.boundedOutput(delta)
            let message = ConversationMessage(
                role: .assistant,
                text: output.text,
                phase: phase,
                turnID: active.remoteTurnID
            )
            document.conversations[conversationIndex].messages.append(message)
            active.assistantMessageIDs[itemID] = message.id
            active.outputTruncated = output.truncated
        }
        document.conversations[conversationIndex].updatedAt = Date()
        refreshVisibleConversation()
    }

    private func replaceAssistant(
        with text: String,
        itemID: String,
        phase: ConversationMessagePhase?,
        active: inout ActiveConversationTurn
    ) {
        guard let conversationIndex = conversationIndex(id: active.conversationID) else { return }
        if let messageID = active.assistantMessageIDs[itemID],
           let messageIndex = document.conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) {
            let output = Self.boundedOutput(text)
            document.conversations[conversationIndex].messages[messageIndex].text = output.text
            if let phase { document.conversations[conversationIndex].messages[messageIndex].phase = phase }
            active.outputTruncated = active.outputTruncated || output.truncated
        } else if document.conversations[conversationIndex].messages.count < AgentConversationStore.maximumMessagesPerConversation {
            let output = Self.boundedOutput(text)
            let message = ConversationMessage(
                role: .assistant,
                text: output.text,
                phase: phase,
                turnID: active.remoteTurnID
            )
            document.conversations[conversationIndex].messages.append(message)
            active.assistantMessageIDs[itemID] = message.id
            active.outputTruncated = output.truncated
        }
        document.conversations[conversationIndex].updatedAt = Date()
        refreshVisibleConversation()
    }

    private func interruptIfNeeded() async {
        guard var active = activeTurn,
              active.stopRequested,
              !active.interruptSent,
              let threadID = active.remoteThreadID,
              let turnID = active.remoteTurnID else { return }
        active.interruptSent = true
        activeTurn = active
        do {
            let response = try await transport.request(
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID],
                expectedProfileID: active.profileID,
                expectedSessionID: active.sessionID
            )
            guard let current = activeTurn,
                  current.generation == active.generation,
                  response.profileID == active.profileID,
                  response.sessionID == active.sessionID else { return }
        } catch {
            guard activeTurn?.generation == active.generation else { return }
            failActiveTurn(error)
        }
    }

    private func handleConnectionChange() {
        let newProfileID = transport.selectedProfileID
        if newProfileID != observedProfileID {
            clearLiveProgress()
            let previousProfileID = observedProfileID
            generation += 1
            retainedTelemetryTurn = nil
            lastRequestInputContext = nil
            cancelPendingFileChangesSoon(reinstallHandler: true)
            if let active = activeTurn {
                finishActivities(for: active, status: "failed")
                activeTurn = nil
                activity = .failed(message: "The connection changed, so the previous response was detached.")
                persistAfterEvent()
            }
            observedProfileID = newProfileID
            pauseQueues(for: previousProfileID, message: "Queue paused because the connection changed.")
            refreshVisibleConversation()
        } else if activeTurn != nil {
            if case .connected = transport.connectionState {
                // Keep the active turn.
            } else {
                clearLiveProgress()
                generation += 1
                retainedTelemetryTurn = nil
                lastRequestInputContext = nil
                if let active = activeTurn {
                    finishActivities(for: active, status: "failed")
                }
                activeTurn = nil
                cancelPendingFileChangesSoon(reinstallHandler: true)
                activity = .failed(message: transport.connectionState.statusText)
                pauseQueues(for: observedProfileID, message: "Queue paused because the connection disconnected.")
                persistAfterEvent()
            }
        } else if case .connected = transport.connectionState {
            // Existing per-thread telemetry remains persisted, but is not presented until a
            // current connected session can establish its identity again.
        } else {
            retainedTelemetryTurn = nil
            lastRequestInputContext = nil
        }
        notifyObservers()
    }

    private func refreshVisibleConversation() {
        guard loaded, let profileID = transport.selectedProfileID else {
            threads = []
            selectedThreadID = nil
            messages = []
            draft = ""
            selectedModelID = nil
            selectedEffort = nil
            lastRequestInputContext = nil
            turnActivitySummaries = []
            queuedMessages = []
            queuedMessageInFlightID = nil
            queueIsPaused = false
            queueError = nil
            return
        }
        threads = document.conversations
            .filter { $0.profileID == profileID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ConversationThread(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        let savedSelection = document.selectedThreadIDs[profileID.uuidString]
        let selection = savedSelection.flatMap { id in
            document.conversations.contains(where: { $0.id == id && $0.profileID == profileID }) ? id : nil
        } ?? threads.first?.id
        selectedThreadID = selection
        if let selection, let conversation = document.conversations.first(where: { $0.id == selection }) {
            mode = conversation.mode ?? .build
            messages = conversation.messages
            draft = conversation.draft
            selectedModelID = conversation.modelID
            selectedEffort = conversation.reasoningEffort
            if let usage = conversation.inputContextUsage, usage.modelID == conversation.modelID {
                lastRequestInputContext = usage
            } else {
                lastRequestInputContext = nil
            }
            turnActivitySummaries = conversation.activitySummaries ?? []
            queuedMessages = conversation.queuedMessages ?? []
            queueIsPaused = conversation.queueIsPaused ?? false
            queueError = conversation.queueError
        } else {
            messages = []
            draft = ""
            selectedModelID = nil
            selectedEffort = nil
            lastRequestInputContext = nil
            turnActivitySummaries = []
            queuedMessages = []
            queuedMessageInFlightID = nil
            queueIsPaused = false
            queueError = nil
        }
    }

    private func pauseQueue(after error: Error) {
        pauseQueue(message: Self.safe(error))
    }

    private func pauseQueue(message: String) {
        guard let index = selectedConversationIndex else {
            queueIsPaused = true
            queueError = message
            notifyObservers()
            return
        }
        document.conversations[index].queueIsPaused = true
        document.conversations[index].queueError = message
        queueIsPaused = true
        queueError = message
        persistAfterEvent()
        notifyObservers()
    }

    private func pauseQueue(conversationID: UUID, profileID: UUID, message: String) {
        guard let index = document.conversations.firstIndex(where: {
            $0.id == conversationID && $0.profileID == profileID
        }) else { return }
        document.conversations[index].queueIsPaused = true
        document.conversations[index].queueError = message
        if selectedThreadID == conversationID, transport.selectedProfileID == profileID {
            queueIsPaused = true
            queueError = message
        }
        persistAfterEvent()
        notifyObservers()
    }

    private func pauseQueues(for profileID: UUID?, message: String) {
        guard let profileID else { return }
        for index in document.conversations.indices where document.conversations[index].profileID == profileID &&
            !(document.conversations[index].queuedMessages ?? []).isEmpty {
            document.conversations[index].queueIsPaused = true
            document.conversations[index].queueError = message
        }
    }

    private func drainQueueIfPossible(conversationID: UUID? = nil, profileID: UUID? = nil) async {
        guard !isShutdown,
              !queueOperationInFlight,
              !queueIsPaused,
              activeTurn == nil,
              case .connected = connectionState,
              let index = selectedConversationIndex,
              let message = document.conversations[index].queuedMessages?.first else { return }
        if let conversationID, document.conversations[index].id != conversationID { return }
        if let profileID, document.conversations[index].profileID != profileID { return }
        queueOperationInFlight = true
        queuedMessageInFlightID = message.id
        notifyObservers()
        defer {
            queueOperationInFlight = false
            if queuedMessageInFlightID == message.id { queuedMessageInFlightID = nil }
            notifyObservers()
        }
        await startTurn(queuedMessage: message)
    }

    private var selectedConversationIndex: Int? {
        guard let selectedThreadID, let profileID = transport.selectedProfileID else { return nil }
        return document.conversations.firstIndex {
            $0.id == selectedThreadID && $0.profileID == profileID
        }
    }

    private func conversationIndex(id: UUID) -> Int? {
        document.conversations.firstIndex { $0.id == id }
    }

    private func isCurrent(_ expected: Int, profileID: UUID) -> Bool {
        activeTurn?.generation == expected && transport.selectedProfileID == profileID
    }

    private func ensureLoaded() throws {
        guard loaded else {
            throw AgentConversationError.unavailable("Conversations have not loaded yet.")
        }
    }

    private func persist() async throws {
        pruneTelemetry()
        try await store.save(document)
    }

    private func persist(_ snapshot: StoredConversationDocument) async throws {
        try await store.save(snapshot)
    }

    private func pruneTelemetry() {
        let perConversationBudget = 256 * 1_024
        let documentBudget = 256 * 1_024
        for index in document.conversations.indices {
            var summaries = document.conversations[index].activitySummaries ?? []
            while telemetryBytes(in: summaries) > perConversationBudget,
                  pruneOldestTelemetry(from: &summaries) {}
            document.conversations[index].activitySummaries = summaries.isEmpty ? nil : summaries
        }
        while document.conversations.reduce(0, { $0 + telemetryBytes(in: $1.activitySummaries ?? []) }) > documentBudget {
            guard let index = document.conversations.indices.first(where: {
                !(document.conversations[$0].activitySummaries ?? []).isEmpty
            }) else { break }
            var summaries = document.conversations[index].activitySummaries ?? []
            guard pruneOldestTelemetry(from: &summaries) else { break }
            document.conversations[index].activitySummaries = summaries.isEmpty ? nil : summaries
        }
    }

    private func pruneOldestTelemetry(from summaries: inout [ConversationTurnActivitySummary]) -> Bool {
        guard !summaries.isEmpty else { return false }
        if let activityIndex = summaries[0].activities.indices.first(where: {
            summaries[0].activities[$0].output != nil
        }) {
            summaries[0].activities[activityIndex].output = nil
        } else if !summaries[0].activities.isEmpty {
            summaries[0].activities.removeFirst()
        } else {
            summaries.removeFirst()
        }
        return true
    }

    private func telemetryBytes(in summaries: [ConversationTurnActivitySummary]) -> Int {
        summaries.reduce(0) { total, summary in
            total + 128 + telemetryStringBytes(summary.remoteTurnID) + summary.activities.reduce(0) { activityTotal, activity in
                activityTotal + 256 + telemetryStringBytes(activity.itemID) + telemetryStringBytes(activity.operation)
                    + telemetryStringBytes(activity.status) + telemetryStringBytes(activity.output)
            }
        }
    }

    private func telemetryStringBytes(_ value: String?) -> Int {
        // JSON escaping can expand individual UTF-8 bytes; reserve six times the source size so
        // the telemetry budget stays conservative without encoding the document on the main actor.
        6 * (value?.utf8.count ?? 0)
    }

    private func scheduleDraftPersistence() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                try await self.persist()
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error)
            }
        }
    }

    private func scheduleHistoryPersistence() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                try await self.persist()
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error)
            }
        }
    }

    private func persistAfterEvent(drainConversation: (UUID, UUID)? = nil) {
        if let drainConversation {
            // Completion is the only automatic-drain trigger. Keep its persistence independent
            // from coalesced draft/history saves so a late UI update cannot cancel the drain.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.persist()
                    await self.drainQueueIfPossible(
                        conversationID: drainConversation.0,
                        profileID: drainConversation.1
                    )
                } catch {
                    self.fail(error)
                }
            }
            return
        }
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persist()
            } catch {
                self.fail(error)
            }
        }
    }

    private func failActiveTurn(_ error: Error) {
        clearLiveProgress()
        if let active = activeTurn {
            finishActivities(for: active, status: "failed")
        }
        activeTurn = nil
        retainedTelemetryTurn = nil
        cancelPendingFileChangesSoon(reinstallHandler: true)
        activity = .failed(message: Self.safe(error))
        refreshVisibleConversation()
        persistAfterEvent()
        notifyObservers()
    }

    private func fail(_ error: Error) {
        activity = .failed(message: Self.safe(error))
        notifyObservers()
    }

    private func clearLiveProgress() {
        liveProgressText = nil
        liveProgressUserMessageID = nil
        liveProgressItemID = nil
        liveProgressSummaryIndex = nil
    }

    private func notifyObservers() {
        for observer in observers.values { observer() }
    }

    private static func title(from message: String) -> String {
        let visibleMessage: String
        if let envelope = message.range(of: "\n\n<fs_code_attachments>") {
            visibleMessage = String(message[..<envelope.lowerBound])
        } else {
            visibleMessage = message
        }
        let compact = visibleMessage
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard compact.count > 60 else { return compact }
        return String(compact.prefix(57)) + "…"
    }

    private static func boundedOutput(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > AgentConversationStore.maximumTextBytes else { return (text, false) }
        let suffix = "\n\n[Response truncated by FS Code at the 512 KiB local history limit.]"
        let maximumPrefixBytes = AgentConversationStore.maximumTextBytes - suffix.utf8.count
        return (utf8Prefix(text, maximumBytes: maximumPrefixBytes) + suffix, true)
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var end = text.startIndex
        var bytes = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let nextBytes = text[end..<next].utf8.count
            guard bytes + nextBytes <= maximumBytes else { break }
            bytes += nextBytes
            end = next
        }
        return String(text[..<end])
    }

    private static func finalAgentText(in turn: [String: Any]) -> (itemID: String, text: String)? {
        guard let items = turn["items"] as? [[String: Any]] else { return nil }
        guard let item = items.reversed().first(where: { $0["type"] as? String == "agentMessage" }),
              let itemID = item["id"] as? String,
              let text = item["text"] as? String else {
            return nil
        }
        return (itemID, text)
    }

    private static func safe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Codex could not complete the request."
    }
}
