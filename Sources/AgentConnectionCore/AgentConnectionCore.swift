import Foundation
import Darwin
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    case chatGPT
    case openAIAPI
}

public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var selectedModelID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind,
        selectedModelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.selectedModelID = selectedModelID
    }
}

public struct ConnectionModel: Codable, Hashable, Identifiable, Sendable {
    /// The identifier accepted by Codex when starting a turn (`model` in model/list).
    public let id: String
    /// The catalog row identifier returned by model/list.
    public let catalogID: String
    public let displayName: String
    public let isDefault: Bool
    public let supportedReasoningEfforts: [String]
    public let defaultReasoningEffort: String?

    public init(
        id: String,
        catalogID: String? = nil,
        displayName: String,
        isDefault: Bool,
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.catalogID = catalogID ?? id
        self.displayName = displayName
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

struct AgentConnectionRuntimeEvent: @unchecked Sendable {
    let profileID: UUID
    let sessionID: UUID
    let method: String
    let params: [String: Any]
}

struct AgentConnectionRuntimeResponse: @unchecked Sendable {
    let profileID: UUID
    let sessionID: UUID
    let result: [String: Any]
}

public enum AgentRPCRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)
}

public indirect enum AgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AgentJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AgentJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    init?(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                let decimal = value.decimalValue
                let integer = value.int64Value
                if Decimal(integer) == decimal {
                    self = .integer(integer)
                } else {
                    let number = value.doubleValue
                    guard number.isFinite else { return nil }
                    self = .number(number)
                }
            }
        case let value as [Any]:
            var values: [AgentJSONValue] = []
            values.reserveCapacity(value.count)
            for item in value {
                guard let converted = AgentJSONValue(jsonObject: item) else { return nil }
                values.append(converted)
            }
            self = .array(values)
        case let value as [String: Any]:
            var values: [String: AgentJSONValue] = [:]
            values.reserveCapacity(value.count)
            for (key, item) in value {
                guard let converted = AgentJSONValue(jsonObject: item) else { return nil }
                values[key] = converted
            }
            self = .object(values)
        default:
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.jsonObject)
        case .object(let value): value.mapValues(\.jsonObject)
        }
    }
}

public struct AgentDynamicToolRequest: Sendable, Equatable {
    public let requestID: AgentRPCRequestID
    public let profileID: UUID
    public let sessionID: UUID
    public let threadID: String
    public let turnID: String
    public let callID: String
    public let namespace: String?
    public let toolName: String
    public let arguments: AgentJSONValue
}

public struct AgentDynamicToolResult: Sendable, Equatable {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }

    public static func accepted(_ message: String) -> Self {
        Self(success: true, message: message)
    }

    public static func rejected(_ message: String) -> Self {
        Self(success: false, message: message)
    }
}

public enum AgentConnectionState: Sendable, Equatable {
    case unloaded
    case disconnected
    case connecting
    case awaitingBrowserLogin(URL?)
    case loadingModels
    case connected(accountName: String?)
    case failed(message: String)

    public var statusText: String {
        switch self {
        case .unloaded:
            "Connections have not loaded yet."
        case .disconnected:
            "Not connected"
        case .connecting:
            "Connecting…"
        case .awaitingBrowserLogin:
            "Finish sign-in in your browser."
        case .loadingModels:
            "Loading models…"
        case .connected(let name):
            name.map { "Connected as \($0)" } ?? "Connected"
        case .failed(let message):
            message
        }
    }
}

public enum AgentConnectionError: LocalizedError, Sendable, Equatable {
    case noSelectedProfile
    case invalidName
    case noAPIKey
    case executableUnavailable
    case invalidExecutable
    case apiKeyUnverified
    case cancelled
    case corruptStore
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noSelectedProfile:
            "Select a connection first."
        case .invalidName:
            "Connection name cannot be empty."
        case .noAPIKey:
            "Enter an API key to connect this profile."
        case .executableUnavailable:
            "Codex App Server could not be found."
        case .invalidExecutable:
            "The selected Codex executable is not available."
        case .apiKeyUnverified:
            "The API key could not be verified."
        case .cancelled:
            "Connection was cancelled."
        case .corruptStore:
            "Saved connections could not be read. They were left unchanged."
        case .unavailable(let message):
            message
        }
    }
}

private struct StoredConnections: Codable, Equatable {
    var version = 1
    var profiles: [ConnectionProfile] = []
    var selectedProfileID: UUID?
    var executablePath: String?

    func validated() throws -> StoredConnections {
        guard version == 1 else { throw AgentConnectionError.corruptStore }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw AgentConnectionError.corruptStore
        }
        guard profiles.allSatisfy({
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw AgentConnectionError.corruptStore
        }
        if let selectedProfileID,
           !profiles.contains(where: { $0.id == selectedProfileID }) {
            throw AgentConnectionError.corruptStore
        }
        if let executablePath,
           (executablePath.isEmpty || !URL(fileURLWithPath: executablePath).path.hasPrefix("/")) {
            throw AgentConnectionError.corruptStore
        }
        return self
    }
}

/// Metadata-only store. Credentials remain in Codex's keyring for each isolated home.
private actor ConnectionProfileStore {
    let fileURL: URL
    let projectRoot: URL?

    init(fileURL: URL, projectRoot: URL? = nil) {
        self.fileURL = fileURL
        self.projectRoot = projectRoot
    }

    func load() throws -> StoredConnections {
        try validateProjectStorage(createDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StoredConnections()
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= 1_048_576 else {
                throw AgentConnectionError.corruptStore
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            return try JSONDecoder().decode(StoredConnections.self, from: data).validated()
        } catch let error as AgentConnectionError {
            throw error
        } catch {
            throw AgentConnectionError.corruptStore
        }
    }

    func save(_ value: StoredConnections) throws {
        let validated = try value.validated()
        let directory = fileURL.deletingLastPathComponent()
        try validateProjectStorage(createDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateProjectStorage(createDirectory: false)
        let data = try JSONEncoder().encode(validated)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validateProjectStorage(createDirectory: Bool) throws {
        guard let projectRoot else { return }
        for (url, mustBeDirectory) in [
            (projectRoot, true),
            (fileURL.deletingLastPathComponent(), true),
            (fileURL, false)
        ] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw AgentConnectionError.corruptStore
                }
                let expected = mustBeDirectory ? S_IFDIR : S_IFREG
                guard (info.st_mode & S_IFMT) == expected else {
                    throw AgentConnectionError.corruptStore
                }
            } else if errno == ENOENT {
                if url == projectRoot { throw AgentConnectionError.corruptStore }
                if !mustBeDirectory && createDirectory == false { continue }
                if mustBeDirectory, createDirectory { continue }
                if !mustBeDirectory { continue }
            } else {
                throw AgentConnectionError.corruptStore
            }
        }
    }
}

@MainActor
public final class AgentConnectionManager {
    public typealias Observer = @MainActor @Sendable () -> Void
    public typealias DynamicToolHandler = @MainActor @Sendable (
        AgentDynamicToolRequest
    ) async -> AgentDynamicToolResult

    public private(set) var profiles: [ConnectionProfile] = []
    public private(set) var selectedProfileID: UUID?
    public private(set) var models: [ConnectionModel] = []
    public private(set) var state: AgentConnectionState = .unloaded
    public private(set) var pendingLoginURL: URL?
    public private(set) var pendingDeviceCode: String?
    public var resolveAgentInstructions: (@MainActor () async throws -> String)?
    private var nativeProjectID: UUID?
    private var nativeProjectRoot: URL?
    private static let nativeCredentials = KeychainProjectCredentialStore()
    private static let nativeOAuth = ChatGPTOAuthClient(store: nativeCredentials)
    private var credentialStore: any ProjectCredentialStore = AgentConnectionManager.nativeCredentials
    private var oauthClient = AgentConnectionManager.nativeOAuth
    private var nativeCatalogLoader: (@MainActor (ConnectionProfile) async throws -> [ConnectionModel])?
    private var nativeClientFactory: NativeAgentRuntime.ClientFactory?
    private var nativeLoginTask: Task<ChatGPTOAuthTokens, Error>?
    private var browserLoginSession: BrowserAuthorizationSession?
    private var nativeEnabled: Bool { nativeProjectID != nil && nativeProjectRoot != nil }

    private let supportURL: URL
    private let store: ConnectionProfileStore
    private let runtimeFactory: CodexRuntime.Factory
    private let apiKeyValidator: @Sendable (String) async throws -> Void

    private var stored = StoredConnections()
    private var observers: [UUID: Observer] = [:]
    private var clients = Set<UUID>()
    private var runtime: CodexRuntime?
    private var nativeRuntime: (any AgentEngine)?
    private var runtimeProfileID: UUID?
    private var runtimeSessionID: UUID?
    private var runtimeObservers: [UUID: @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void] = [:]
    private var dynamicToolHandler: (token: UUID, handler: DynamicToolHandler)?
    private var generation = 0
    private var loginID: String?
    private var deferredLoginCompletion: [String: Any]?
    private var didLoad = false
    private var loadTask: Task<StoredConnections, Error>?
    private var metadataLocked = false
    private var metadataWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init(projectURL: URL, projectID: UUID = UUID(), applicationSupportURL: URL? = nil) {
        let canonicalProject = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let support = applicationSupportURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("FS Code", isDirectory: true)
        self.init(
            supportURL: support,
            metadataURL: canonicalProject
                .appendingPathComponent(".fscode", isDirectory: true)
                .appendingPathComponent("connections.json"),
            projectRoot: canonicalProject,
            runtimeFactory: CodexRuntime.live,
            apiKeyValidator: Self.validateAPIKey
        )
        nativeProjectID = projectID
        nativeProjectRoot = canonicalProject
    }

    /// Dependency injection for deterministic connection and engine integration tests.
    convenience init(
        projectURL: URL, projectID: UUID, supportURL: URL,
        credentialStore: any ProjectCredentialStore, oauth: ChatGPTOAuthClient,
        catalogLoader: @escaping @MainActor (ConnectionProfile) async throws -> [ConnectionModel],
        clientFactory: @escaping NativeAgentRuntime.ClientFactory
    ) {
        self.init(projectURL: projectURL, projectID: projectID, applicationSupportURL: supportURL)
        self.credentialStore = credentialStore
        oauthClient = oauth
        nativeCatalogLoader = catalogLoader
        nativeClientFactory = clientFactory
    }

    /// Explicit isolated storage is retained for previews and cross-module tests.
    /// Production workspaces must use `init(projectURL:applicationSupportURL:)`.
    public convenience init(applicationSupportURL: URL) {
        self.init(
            supportURL: applicationSupportURL,
            metadataURL: applicationSupportURL.appendingPathComponent("connections.json"),
            projectRoot: nil,
            runtimeFactory: CodexRuntime.live,
            apiKeyValidator: Self.validateAPIKey
        )
    }

    /// Test-only construction keeps metadata and isolated runtime homes together.
    convenience init(
        applicationSupportURL: URL?,
        runtimeFactory: @escaping CodexRuntime.Factory,
        apiKeyValidator: @escaping @Sendable (String) async throws -> Void
    ) {
        let support = applicationSupportURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("FS Code", isDirectory: true)
        self.init(
            supportURL: support,
            metadataURL: support.appendingPathComponent("connections.json"),
            projectRoot: nil,
            runtimeFactory: runtimeFactory,
            apiKeyValidator: apiKeyValidator
        )
    }

    init(
        supportURL: URL,
        metadataURL: URL,
        projectRoot: URL?,
        runtimeFactory: @escaping CodexRuntime.Factory,
        apiKeyValidator: @escaping @Sendable (String) async throws -> Void
    ) {
        self.supportURL = supportURL
        store = ConnectionProfileStore(fileURL: metadataURL, projectRoot: projectRoot)
        self.runtimeFactory = runtimeFactory
        self.apiKeyValidator = apiKeyValidator
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

    @discardableResult
    func addRuntimeObserver(
        _ observer: @escaping @MainActor @Sendable (AgentConnectionRuntimeEvent) -> Void
    ) -> UUID {
        let id = UUID()
        runtimeObservers[id] = observer
        return id
    }

    func removeRuntimeObserver(_ id: UUID) {
        runtimeObservers.removeValue(forKey: id)
    }

    @discardableResult
    public func setDynamicToolHandler(_ handler: @escaping DynamicToolHandler) -> UUID {
        let token = UUID()
        if dynamicToolHandler != nil { runtime?.cancelDynamicToolCalls() }
        dynamicToolHandler = (token, handler)
        return token
    }

    public func removeDynamicToolHandler(_ token: UUID) {
        guard dynamicToolHandler?.token == token else { return }
        dynamicToolHandler = nil
        runtime?.cancelDynamicToolCalls()
    }

    func requestSelectedRuntime(
        method: String,
        params: [String: Any],
        expectedProfileID: UUID,
        expectedSessionID: UUID? = nil
    ) async throws -> AgentConnectionRuntimeResponse {
        guard let profileID = selectedProfileID,
              profileID == expectedProfileID,
              runtimeProfileID == profileID,
              let sessionID = runtimeSessionID,
              expectedSessionID == nil || expectedSessionID == sessionID,
              case .connected = state else {
            throw AgentConnectionError.unavailable("Connect this model before starting a chat.")
        }

        if let native = nativeRuntime {
            var nativeParams = params
            if (method == "thread/start" || method == "thread/resume"), let resolveAgentInstructions {
                let context = try await resolveAgentInstructions()
                guard nativeRuntime === native, selectedProfileID == profileID, runtimeSessionID == sessionID else {
                    throw AgentConnectionError.cancelled
                }
                nativeParams["developerInstructions"] = [params["developerInstructions"] as? String ?? "", context]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let result = try await native.request(method: method, params: nativeParams)
            guard nativeRuntime === native, runtimeProfileID == profileID, runtimeSessionID == sessionID else {
                throw AgentConnectionError.cancelled
            }
            return AgentConnectionRuntimeResponse(profileID: profileID, sessionID: sessionID, result: result)
        }
        guard let instance = runtime else {
            throw AgentConnectionError.unavailable("Connect this model before starting a chat.")
        }
        let response = try await instance.request(
            method: method,
            params: CodexRuntime.Parameters(params)
        )
        guard runtime === instance,
              runtimeProfileID == profileID,
              runtimeSessionID == sessionID,
              profileID == expectedProfileID,
              expectedSessionID == nil || expectedSessionID == sessionID,
              selectedProfileID == profileID else {
            throw AgentConnectionError.cancelled
        }
        return AgentConnectionRuntimeResponse(
            profileID: profileID,
            sessionID: sessionID,
            result: response.object
        )
    }

    /// Views retain the shared runtime while visible. Releasing the last client stops
    /// the process but keeps that profile's keyring session intact.
    @discardableResult
    public func acquireClient() -> UUID {
        let id = UUID()
        clients.insert(id)
        return id
    }

    public func releaseClient(_ id: UUID) async {
        clients.remove(id)
        guard clients.isEmpty else { return }

        generation += 1
        let expected = generation
        stopRuntime()
        guard expected == generation, clients.isEmpty else { return }
        models = []
        clearLogin()
        apply(.disconnected)
    }

    public func load() async throws {
        if didLoad { return }

        let task: Task<StoredConnections, Error>
        if let loadTask {
            task = loadTask
        } else {
            let store = self.store
            task = Task { try await store.load() }
            loadTask = task
        }

        do {
            let loaded = try await task.value
            guard !didLoad else { return }
            stored = loaded
            profiles = loaded.profiles
            selectedProfileID = loaded.selectedProfileID
            didLoad = true
            loadTask = nil
            apply(.disconnected)
        } catch {
            loadTask = nil
            apply(.failed(message: AgentConnectionError.corruptStore.localizedDescription))
            throw AgentConnectionError.corruptStore
        }
    }

    public func createProfile(
        name: String,
        kind: ConnectionKind,
        apiKey: String?
    ) async throws -> ConnectionProfile {
        try await load()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw AgentConnectionError.invalidName }

        if kind == .openAIAPI {
            guard let apiKey, !apiKey.isEmpty else { throw AgentConnectionError.noAPIKey }
            do {
                try await apiKeyValidator(apiKey)
            } catch {
                throw AgentConnectionError.apiKeyUnverified
            }
        }

        let profile = ConnectionProfile(name: cleanName, kind: kind)
        try await withMetadataLock {
            let previousProfiles = profiles
            let previousSelection = selectedProfileID
            profiles.append(profile)
            selectedProfileID = profile.id

            do {
                try await persistMetadata()
            } catch {
                profiles = previousProfiles
                selectedProfileID = previousSelection
                throw error
            }
        }
        notifyObservers()

        if kind == .openAIAPI {
            await connect(
                apiKey: apiKey,
                refresh: false,
                validateSuppliedKey: false,
                expectedProfileID: profile.id
            )
        }
        return profile
    }

    public func renameProfile(id: UUID, name: String) async throws {
        try await load()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw AgentConnectionError.invalidName }
        try await withMetadataLock {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            let oldName = profiles[index].name
            profiles[index].name = cleanName
            do {
                try await persistMetadata()
            } catch {
                if let rollbackIndex = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[rollbackIndex].name = oldName
                }
                throw error
            }
        }
        notifyObservers()
    }

    public func removeProfile(id: UUID) async throws {
        try await load()
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        let removesCurrentProfile = selectedProfileID == id || runtimeProfileID == id
        if removesCurrentProfile { generation += 1 }
        let expected = generation
        if runtimeProfileID == id { stopRuntime() }
        guard expected == generation else { throw AgentConnectionError.cancelled }
        try await logout(profile: profile, generation: expected)
        guard isCurrent(expected) else { throw AgentConnectionError.cancelled }

        try await withMetadataLock {
            guard expected == generation else { throw AgentConnectionError.cancelled }
            let previousProfiles = profiles
            let previousSelection = selectedProfileID
            profiles.removeAll { $0.id == id }
            if selectedProfileID == id { selectedProfileID = nil }

            do {
                try await persistMetadata()
            } catch {
                profiles = previousProfiles
                selectedProfileID = previousSelection
                throw error
            }
        }

        guard expected == generation else { return }

        if removesCurrentProfile {
            models = []
            clearLogin()
            apply(.disconnected)
        } else {
            notifyObservers()
        }
        if !nativeEnabled { try? FileManager.default.removeItem(at: homeURL(for: profile.id)) }
    }

    public func selectProfile(id: UUID?) async {
        do { try await load() } catch { return }
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        guard id != selectedProfileID else { return }

        generation += 1
        let expected = generation
        do {
            try await withMetadataLock {
                guard expected == generation else { throw AgentConnectionError.cancelled }
                let previousSelection = selectedProfileID
                selectedProfileID = id
                do {
                    try await persistMetadata()
                } catch {
                    selectedProfileID = previousSelection
                    throw error
                }
            }
        } catch {
            guard expected == generation else { return }
            apply(.failed(message: "The selected connection could not be saved."))
            return
        }
        guard expected == generation else { return }

        stopRuntime()
        guard expected == generation else { return }
        models = []
        clearLogin()
        apply(.disconnected)
    }

    public func connectSelected(apiKey: String? = nil) async {
        await connect(
            apiKey: apiKey,
            refresh: false,
            validateSuppliedKey: true,
            expectedProfileID: nil
        )
    }

    public func refreshSelected() async {
        await connect(
            apiKey: nil,
            refresh: true,
            validateSuppliedKey: true,
            expectedProfileID: nil
        )
    }

    public func cancelLogin() async {
        browserLoginSession?.cancel()
        browserLoginSession = nil
        nativeLoginTask?.cancel()
        nativeLoginTask = nil
        generation += 1
        let expected = generation
        let instance = runtime
        let id = loginID
        clearLogin()

        if let instance, let id {
            _ = try? await instance.request(
                method: "account/login/cancel",
                params: ["loginId": id]
            )
        }
        guard expected == generation else { return }
        stopRuntime(ifCurrent: instance)
        guard expected == generation else { return }
        models = []
        apply(.disconnected)
    }

    public func logoutSelected() async {
        guard let profile = selectedProfile else {
            apply(.failed(message: AgentConnectionError.noSelectedProfile.localizedDescription))
            return
        }

        generation += 1
        let expected = generation
        do {
            try await logout(profile: profile, generation: expected)
            guard isCurrent(expected, profileID: profile.id) else { return }
            models = []
            clearLogin()
            apply(.disconnected)
        } catch {
            guard expected == generation else { return }
            apply(.failed(message: Self.safe(error)))
        }
    }

    public func selectModel(id: String?) async throws {
        try await load()
        try await withMetadataLock {
            guard let profileID = selectedProfileID,
                  let index = profiles.firstIndex(where: { $0.id == profileID }) else {
                throw AgentConnectionError.noSelectedProfile
            }
            guard id == nil || models.contains(where: { $0.id == id }) else {
                throw AgentConnectionError.unavailable("That model is no longer available.")
            }

            let previousID = profiles[index].selectedModelID
            profiles[index].selectedModelID = id
            do {
                try await persistMetadata()
            } catch {
                if let rollbackIndex = profiles.firstIndex(where: { $0.id == profileID }) {
                    profiles[rollbackIndex].selectedModelID = previousID
                }
                throw error
            }
        }
        notifyObservers()
    }

    public func configureCodexExecutable(at url: URL?) async throws {
        try await load()
        let path: String?
        if let url {
            guard Self.resolveExecutableCandidate(url.path) != nil else {
                throw AgentConnectionError.invalidExecutable
            }
            path = url.path
        } else {
            path = nil
        }

        try await withMetadataLock {
            let previousPath = stored.executablePath
            stored.executablePath = path
            do {
                try await persistMetadata()
            } catch {
                stored.executablePath = previousPath
                throw error
            }
        }
        notifyObservers()
    }

    private var selectedProfile: ConnectionProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    private func connect(
        apiKey: String?,
        refresh: Bool,
        validateSuppliedKey: Bool,
        expectedProfileID: UUID?
    ) async {
        if let expectedProfileID, selectedProfileID != expectedProfileID { return }
        generation += 1
        let expected = generation
        guard let profile = selectedProfile else {
            apply(.failed(message: AgentConnectionError.noSelectedProfile.localizedDescription))
            return
        }

        if profile.kind == .openAIAPI, let apiKey, validateSuppliedKey {
            do {
                try await apiKeyValidator(apiKey)
            } catch {
                guard isCurrent(expected, profileID: profile.id) else { return }
                apply(.failed(message: AgentConnectionError.apiKeyUnverified.localizedDescription))
                return
            }
            guard isCurrent(expected, profileID: profile.id) else { return }
        }

        apply(.connecting)
        stopRuntime()
        guard isCurrent(expected, profileID: profile.id) else { return }
        clearLogin()

        do {
            try await performConnection(
                profile: profile,
                apiKey: apiKey,
                refresh: refresh,
                generation: expected
            )
        } catch {
            guard isCurrent(expected, profileID: profile.id) else { return }
            apply(.failed(message: Self.safe(error)))
            stopRuntime()
        }
    }

    private func performNativeConnection(
        profile: ConnectionProfile, apiKey: String?, refresh: Bool, generation expected: Int
    ) async throws {
        guard let projectID = nativeProjectID, let root = nativeProjectRoot else {
            throw AgentConnectionError.cancelled
        }
        let scope = ProjectCredentialScope(projectID: projectID, profileID: profile.id)
        let snapshot = try await credentialStore.snapshot(for: scope)
        if profile.kind == .openAIAPI, let apiKey {
            guard isCurrent(expected, profileID: profile.id) else { throw AgentConnectionError.cancelled }
            guard try await credentialStore.replace(.apiKey(apiKey), for: scope, ifGeneration: snapshot.generation) else {
                throw AgentConnectionError.cancelled
            }
        } else if snapshot.credential == nil {
            guard profile.kind == .chatGPT, !refresh else {
                throw AgentConnectionError.unavailable("Sign in again to connect this project to the native engine. Existing chats are preserved.")
            }
            let session = try await oauthClient.startBrowserAuthorization()
            defer {
                session.cancel()
                if browserLoginSession === session { browserLoginSession = nil }
            }
            guard isCurrent(expected, profileID: profile.id) else { throw AgentConnectionError.cancelled }
            browserLoginSession = session
            pendingLoginURL = session.authorizationURL
            pendingDeviceCode = nil
            apply(.awaitingBrowserLogin(session.authorizationURL))
            let oauth = oauthClient
            let task = Task {
                let code = try await session.waitForCode()
                try Task.checkCancellation()
                return try await oauth.exchangeBrowserAuthorization(code: code, session: session)
            }
            nativeLoginTask = task
            let tokens = try await task.value
            guard !Task.isCancelled, isCurrent(expected, profileID: profile.id) else { throw AgentConnectionError.cancelled }
            guard try await credentialStore.replace(.chatGPT(tokens), for: scope, ifGeneration: snapshot.generation) else {
                throw AgentConnectionError.cancelled
            }
            nativeLoginTask = nil
        }
        guard isCurrent(expected, profileID: profile.id) else { throw AgentConnectionError.cancelled }
        clearLogin()
        apply(.loadingModels)
        let provider = NativeProviderConnection(scope: scope, kind: profile.kind, credentials: credentialStore, oauth: oauthClient)
        let catalog: [ConnectionModel]
        if let nativeCatalogLoader { catalog = try await nativeCatalogLoader(profile) }
        else { catalog = try await provider.fetchModels() }
        guard !catalog.isEmpty else { throw AgentConnectionError.unavailable("No compatible models were returned for this account.") }
        guard isCurrent(expected, profileID: profile.id) else { throw AgentConnectionError.cancelled }
        let sessionID = UUID()
        let engine = NativeAgentRuntime(configuration: .init(
            projectID: projectID, projectRoot: root, profileID: profile.id, sessionID: sessionID,
            modelID: profile.selectedModelID ?? catalog.first?.id, effort: nil, historyRoot: supportURL
        ), makeClient: nativeClientFactory ?? { configuration in try await provider.makeClient(configuration: configuration) },
        dynamicToolHandler: { [weak self] request in
            guard let self, self.isCurrent(expected, profileID: profile.id),
                  self.runtimeSessionID == sessionID, let registered = self.dynamicToolHandler else {
                return .rejected("This project connection is no longer active.")
            }
            let result = await registered.handler(request)
            guard !Task.isCancelled, self.isCurrent(expected, profileID: profile.id),
                  self.runtimeSessionID == sessionID, self.dynamicToolHandler?.token == registered.token else {
                return .rejected("The tool request was cancelled.")
            }
            return result
        })
        engine.onNotification = { [weak self] method, params in
            guard let self, self.isCurrent(expected, profileID: profile.id), self.runtimeSessionID == sessionID else { return }
            let event = AgentConnectionRuntimeEvent(profileID: profile.id, sessionID: sessionID, method: method, params: params)
            for observer in self.runtimeObservers.values { observer(event) }
        }
        nativeRuntime = engine
        runtimeProfileID = profile.id
        runtimeSessionID = sessionID
        models = catalog
        apply(.connected(accountName: profile.name))
    }

    private func performConnection(
        profile: ConnectionProfile,
        apiKey: String?,
        refresh: Bool,
        generation expected: Int
    ) async throws {
        if nativeEnabled {
            try await performNativeConnection(profile: profile, apiKey: apiKey, refresh: refresh, generation: expected)
            return
        }
        let executable = try discoverExecutable()
        let instance = try runtimeFactory(executable, homeURL(for: profile.id))
        let sessionID = UUID()
        instance.onNotification = { [weak self, weak instance] notification in
            guard let instance else { return }
            Task { @MainActor [weak self] in
                await self?.handleRuntimeNotification(
                    method: notification.method,
                    params: notification.params,
                    runtime: instance,
                    profileID: profile.id,
                    sessionID: sessionID,
                    generation: expected
                )
            }
        }
        instance.onTermination = { [weak self, weak instance] error in
            guard let instance else { return }
            Task { @MainActor [weak self] in
                self?.handleRuntimeTermination(
                    error,
                    runtime: instance,
                    profileID: profile.id,
                    sessionID: sessionID,
                    generation: expected
                )
            }
        }
        instance.onDynamicToolCall = { [weak self, weak instance] call in
            guard let self, let instance else {
                return .rejected("The project connection is no longer available.")
            }
            return await self.handleDynamicToolCall(
                call,
                runtime: instance,
                profileID: profile.id,
                sessionID: sessionID,
                generation: expected
            )
        }
        runtime = instance
        runtimeProfileID = profile.id
        runtimeSessionID = sessionID

        try instance.start()
        let initializeParams: CodexRuntime.Parameters = [
            "clientInfo": ["name": "fs_code", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ]
        _ = try await instance.request(
            method: "initialize",
            params: initializeParams
        )
        guard owns(instance, generation: expected, profileID: profile.id) else { return }
        try instance.notify(method: "initialized", params: [:])

        if profile.kind == .openAIAPI, let apiKey {
            _ = try await instance.request(
                method: "account/login/start",
                params: ["type": "apiKey", "apiKey": apiKey]
            )
            guard owns(instance, generation: expected, profileID: profile.id) else { return }
        }

        let accountReadParams: CodexRuntime.Parameters = ["refreshToken": refresh]
        let accountResponse = try await instance.request(
            method: "account/read",
            params: accountReadParams
        ).object
        guard owns(instance, generation: expected, profileID: profile.id) else { return }
        await finishConnection(
            profile: profile,
            accountResponse: accountResponse,
            refresh: refresh,
            runtime: instance,
            generation: expected
        )
    }

    private func finishConnection(
        profile: ConnectionProfile,
        accountResponse: [String: Any],
        refresh: Bool,
        runtime instance: CodexRuntime,
        generation expected: Int
    ) async {
        guard let accountKind = Self.accountKind(in: accountResponse) else {
            if profile.kind == .chatGPT, !refresh {
                await startBrowserLogin(profile: profile, runtime: instance, generation: expected)
                return
            }
            stopRuntime(ifCurrent: instance)
            guard expected == generation else { return }
            models = []
            clearLogin()
            apply(.disconnected)
            return
        }

        guard accountKind == profile.kind else {
            stopRuntime(ifCurrent: instance)
            guard expected == generation else { return }
            models = []
            clearLogin()
            apply(.failed(message: "The saved account does not match this connection type."))
            return
        }

        do {
            apply(.loadingModels)
            let fetchedModels = try await fetchModels(from: instance)
            guard owns(instance, generation: expected, profileID: profile.id) else { return }
            guard !fetchedModels.isEmpty else {
                throw AgentConnectionError.unavailable(
                    "Connected, but no models are available for this account."
                )
            }
            models = fetchedModels
            clearLogin()
            apply(.connected(accountName: Self.accountName(in: accountResponse)))
        } catch {
            guard owns(instance, generation: expected, profileID: profile.id) else { return }
            apply(.failed(message: Self.safe(error)))
            stopRuntime(ifCurrent: instance)
        }
    }

    private func startBrowserLogin(
        profile: ConnectionProfile,
        runtime instance: CodexRuntime,
        generation expected: Int
    ) async {
        do {
            let login = try await instance.request(
                method: "account/login/start",
                params: [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": false
                ]
            ).object
            guard owns(instance, generation: expected, profileID: profile.id) else { return }
            guard login["type"] as? String == "chatgpt",
                  let id = login["loginId"] as? String,
                  !id.isEmpty else {
                throw CodexRuntime.RuntimeError.malformed
            }
            loginID = id
            pendingLoginURL = Self.loginURL(in: login)
            apply(.awaitingBrowserLogin(pendingLoginURL))
            if let deferred = deferredLoginCompletion,
               deferred["loginId"] as? String == id {
                deferredLoginCompletion = nil
                await handleNotification(
                    method: "account/login/completed",
                    params: deferred,
                    runtime: instance,
                    profileID: profile.id,
                    generation: expected
                )
            }
        } catch {
            guard owns(instance, generation: expected, profileID: profile.id) else { return }
            apply(.failed(message: Self.safe(error)))
            stopRuntime(ifCurrent: instance)
        }
    }

    private func handleNotification(
        method: String,
        params: [String: Any],
        runtime instance: CodexRuntime,
        profileID: UUID,
        generation expected: Int
    ) async {
        guard method == "account/login/completed" else { return }
        guard owns(instance, generation: expected, profileID: profileID) else { return }
        guard let expectedLoginID = loginID,
              params["loginId"] as? String == expectedLoginID else { return }

        guard params["success"] as? Bool == true else {
            clearLogin()
            apply(.failed(message: "ChatGPT sign-in did not complete."))
            stopRuntime(ifCurrent: instance)
            return
        }

        do {
            let account = try await instance.request(
                method: "account/read",
                params: ["refreshToken": true]
            ).object
            guard owns(instance, generation: expected, profileID: profileID) else { return }
            guard Self.accountKind(in: account) == .chatGPT else {
                throw CodexRuntime.RuntimeError.malformed
            }

            apply(.loadingModels)
            let fetchedModels = try await fetchModels(from: instance)
            guard owns(instance, generation: expected, profileID: profileID) else { return }
            guard !fetchedModels.isEmpty else {
                throw AgentConnectionError.unavailable(
                    "Connected, but no models are available for this account."
                )
            }
            models = fetchedModels
            clearLogin()
            apply(.connected(accountName: Self.accountName(in: account)))
        } catch {
            guard owns(instance, generation: expected, profileID: profileID) else { return }
            clearLogin()
            apply(.failed(message: Self.safe(error)))
            stopRuntime(ifCurrent: instance)
        }
    }

    private func handleRuntimeNotification(
        method: String,
        params: [String: Any],
        runtime instance: CodexRuntime,
        profileID: UUID,
        sessionID: UUID,
        generation expected: Int
    ) async {
        guard owns(instance, generation: expected, profileID: profileID),
              runtimeSessionID == sessionID else { return }

        let event = AgentConnectionRuntimeEvent(
            profileID: profileID,
            sessionID: sessionID,
            method: method,
            params: params
        )
        for observer in runtimeObservers.values { observer(event) }

        if method == "account/login/completed", loginID == nil {
            deferredLoginCompletion = params
            return
        }
        await handleNotification(
            method: method,
            params: params,
            runtime: instance,
            profileID: profileID,
            generation: expected
        )
    }

    private func handleRuntimeTermination(
        _ error: CodexRuntime.RuntimeError,
        runtime instance: CodexRuntime,
        profileID: UUID,
        sessionID: UUID,
        generation expected: Int
    ) {
        guard owns(instance, generation: expected, profileID: profileID),
              runtimeSessionID == sessionID else { return }

        stopRuntime(ifCurrent: instance)
        models = []
        clearLogin()
        apply(.failed(message: Self.safe(error)))
    }

    private func handleDynamicToolCall(
        _ call: CodexRuntime.DynamicToolCall,
        runtime instance: CodexRuntime,
        profileID: UUID,
        sessionID: UUID,
        generation expected: Int
    ) async -> AgentDynamicToolResult {
        guard owns(instance, generation: expected, profileID: profileID),
              runtimeSessionID == sessionID,
              let registered = dynamicToolHandler else {
            return .rejected("The project connection is no longer available.")
        }
        let request = AgentDynamicToolRequest(
            requestID: call.requestID,
            profileID: profileID,
            sessionID: sessionID,
            threadID: call.threadID,
            turnID: call.turnID,
            callID: call.callID,
            namespace: call.namespace,
            toolName: call.toolName,
            arguments: call.arguments
        )
        let result = await registered.handler(request)
        guard !Task.isCancelled,
              dynamicToolHandler?.token == registered.token,
              owns(instance, generation: expected, profileID: profileID),
              runtimeSessionID == sessionID else {
            return .rejected("The tool request was cancelled.")
        }
        return result
    }

    private func fetchModels(from runtime: CodexRuntime) async throws -> [ConnectionModel] {
        var cursor: String?
        var seenCursors = Set<String>()
        var modelsByID: [String: ConnectionModel] = [:]

        for pageIndex in 0..<20 {
            var params: CodexRuntime.Parameters = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }

            let page = try await runtime.request(method: "model/list", params: params).object
            for model in try Self.models(in: page) {
                if modelsByID[model.id] == nil { modelsByID[model.id] = model }
            }

            guard let next = page["nextCursor"] as? String, !next.isEmpty else {
                return modelsByID.values.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            }
            guard seenCursors.insert(next).inserted, pageIndex < 19 else {
                throw CodexRuntime.RuntimeError.malformed
            }
            cursor = next
        }
        throw CodexRuntime.RuntimeError.malformed
    }

    private func logout(profile: ConnectionProfile, generation expected: Int) async throws {
        if nativeEnabled, let projectID = nativeProjectID {
            stopRuntime()
            try await oauthClient.revoke(scope: .init(projectID: projectID, profileID: profile.id))
            return
        }

        let active = runtimeProfileID == profile.id ? runtime : nil
        let instance: CodexRuntime
        let ownsTemporaryRuntime: Bool

        if let active {
            instance = active
            ownsTemporaryRuntime = false
        } else {
            let executable = try discoverExecutable()
            instance = try runtimeFactory(executable, homeURL(for: profile.id))
            ownsTemporaryRuntime = true
            try instance.start()
            do {
                _ = try await instance.request(
                    method: "initialize",
                    params: [
                        "clientInfo": ["name": "fs_code", "version": "1"],
                        "capabilities": ["experimentalApi": true]
                    ]
                )
                guard expected == generation else {
                    instance.stop()
                    throw AgentConnectionError.cancelled
                }
                try instance.notify(method: "initialized", params: [:])
            } catch {
                instance.stop()
                throw error
            }
        }

        do {
            _ = try await instance.request(method: "account/logout", params: [:])
            guard expected == generation else {
                if ownsTemporaryRuntime { instance.stop() }
                throw AgentConnectionError.cancelled
            }
        } catch {
            if ownsTemporaryRuntime { instance.stop() }
            throw error
        }

        if ownsTemporaryRuntime {
            instance.stop()
        } else {
            stopRuntime(ifCurrent: instance)
        }
    }

    private func persistMetadata() async throws {
        var candidate = stored
        candidate.profiles = profiles
        candidate.selectedProfileID = selectedProfileID
        try await store.save(candidate)
        stored = candidate
    }

    private func withMetadataLock<T>(
        _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        await acquireMetadataLock()
        do {
            let result = try await operation()
            releaseMetadataLock()
            return result
        } catch {
            releaseMetadataLock()
            throw error
        }
    }

    private func acquireMetadataLock() async {
        if !metadataLocked {
            metadataLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            metadataWaiters.append(continuation)
        }
    }

    private func releaseMetadataLock() {
        if metadataWaiters.isEmpty {
            metadataLocked = false
        } else {
            metadataWaiters.removeFirst().resume()
        }
    }

    private func stopRuntime(ifCurrent expected: CodexRuntime? = nil) {
        if expected == nil {
            browserLoginSession?.cancel()
            browserLoginSession = nil
            nativeLoginTask?.cancel()
            nativeLoginTask = nil
            nativeRuntime?.stop()
            nativeRuntime = nil
            if runtime == nil { runtimeProfileID = nil; runtimeSessionID = nil }
        }
        guard let instance = runtime else { return }
        if let expected, instance !== expected { return }

        runtime = nil
        runtimeProfileID = nil
        runtimeSessionID = nil
        instance.onNotification = nil
        instance.onTermination = nil
        instance.onDynamicToolCall = nil
        instance.stop()
    }

    private func owns(
        _ instance: CodexRuntime,
        generation expected: Int,
        profileID: UUID
    ) -> Bool {
        expected == generation
            && selectedProfileID == profileID
            && runtimeProfileID == profileID
            && runtime === instance
    }

    private func isCurrent(_ expected: Int, profileID: UUID? = nil) -> Bool {
        guard expected == generation else { return false }
        return profileID == nil || selectedProfileID == profileID
    }

    private func clearLogin() {
        loginID = nil
        pendingLoginURL = nil
        pendingDeviceCode = nil
        deferredLoginCompletion = nil
    }

    private func notifyObservers() {
        for observer in observers.values { observer() }
    }

    private func apply(_ nextState: AgentConnectionState) {
        state = nextState
        notifyObservers()
    }

    private func homeURL(for profileID: UUID) -> URL {
        supportURL
            .appendingPathComponent("Connections", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    private func discoverExecutable() throws -> URL {
        if let configuredPath = stored.executablePath {
            guard let executable = Self.resolveExecutableCandidate(configuredPath) else {
                throw AgentConnectionError.invalidExecutable
            }
            return executable
        }

        let home = NSHomeDirectory()
        #if arch(arm64)
        let npmNative = home + "/.npm-global/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #else
        let npmNative = home + "/.npm-global/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        #endif

        var candidates = [
            npmNative,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.npm-global/bin/codex"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        for candidate in candidates {
            if let executable = Self.resolveExecutableCandidate(candidate) {
                return executable
            }
        }
        throw AgentConnectionError.executableUnavailable
    }

    private static func resolveExecutableCandidate(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let original = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: original.path) else { return nil }
        let resolved = original.resolvingSymlinksInPath()

        let packageRoot: URL
        if resolved.lastPathComponent == "codex.js" {
            packageRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            packageRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()
        }
        #if arch(arm64)
        let native = packageRoot.appendingPathComponent(
            "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        )
        #else
        let native = packageRoot.appendingPathComponent(
            "node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        )
        #endif
        if FileManager.default.isExecutableFile(atPath: native.path) { return native }
        if FileManager.default.isExecutableFile(atPath: resolved.path) { return resolved }
        return original
    }

    nonisolated private static func validateAPIKey(_ apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = NoRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentConnectionError.apiKeyUnverified
        }
    }

    private static func safe(_ error: Error) -> String {
        if error is CancellationError || error as? AgentConnectionError == .cancelled {
            return AgentConnectionError.cancelled.localizedDescription
        }
        if let error = error as? AgentConnectionError {
            return error.localizedDescription
        }
        if let error = error as? BrowserAuthorizationError {
            return error.localizedDescription
        }
        return "The connection could not be completed. Try signing in again."
    }

    private static func loginURL(in value: [String: Any]) -> URL? {
        guard let string = value["authUrl"] as? String else { return nil }
        return URL(string: string)
    }

    private static func accountName(in value: [String: Any]) -> String? {
        (value["account"] as? [String: Any])?["email"] as? String
    }

    private static func accountKind(in value: [String: Any]) -> ConnectionKind? {
        guard let account = value["account"] as? [String: Any] else { return nil }
        switch account["type"] as? String {
        case "chatgpt":
            return .chatGPT
        case "apiKey":
            return .openAIAPI
        default:
            return nil
        }
    }

    private static func models(in value: [String: Any]) throws -> [ConnectionModel] {
        guard let data = value["data"] as? [[String: Any]] else {
            throw CodexRuntime.RuntimeError.malformed
        }
        return data.compactMap { item in
            guard
                item["hidden"] as? Bool != true,
                let modelID = item["model"] as? String,
                !modelID.isEmpty,
                let catalogID = item["id"] as? String,
                !catalogID.isEmpty,
                let displayName = item["displayName"] as? String,
                !displayName.isEmpty
            else {
                return nil
            }

            let efforts = (item["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            return ConnectionModel(
                id: modelID,
                catalogID: catalogID,
                displayName: displayName,
                isDefault: item["isDefault"] as? Bool ?? false,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: item["defaultReasoningEffort"] as? String
            )
        }
    }
}
