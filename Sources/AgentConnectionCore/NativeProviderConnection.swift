import AgentRunKit
import Foundation

@MainActor
final class NativeProviderConnection {
    /// Codex's currently supported catalog protocol version. This is deliberately
    /// independent of FS Editor's app version: the ChatGPT backend uses it to
    /// select models compatible with the client protocol.
    static let chatGPTModelCatalogClientVersion = "0.153.4"

    private let scope: ProjectCredentialScope
    private let kind: ConnectionKind
    private let credentials: any ProjectCredentialStore
    private let oauth: ChatGPTOAuthClient
    private var contextWindows: [String: Int] = [:]

    init(scope: ProjectCredentialScope, kind: ConnectionKind, credentials: any ProjectCredentialStore, oauth: ChatGPTOAuthClient) {
        self.scope = scope; self.kind = kind; self.credentials = credentials; self.oauth = oauth
    }

    private var baseURL: URL {
        kind == .chatGPT ? ResponsesAPIClient.chatGPTBaseURL : ResponsesAPIClient.openAIBaseURL
    }

    func authorizationHeaders() async throws -> [String: String] {
        if kind == .chatGPT {
            let token = try await oauth.accessToken(for: scope)
            guard case let .chatGPT(tokens)? = try await credentials.credential(for: scope), tokens.accessToken == token else {
                throw ChatGPTOAuthError.denied
            }
            let account = ChatGPTOAuthClient.accountMetadata(from: tokens.idToken)?.accountID
                ?? ChatGPTOAuthClient.accountMetadata(from: token)?.accountID
            guard let account, !account.isEmpty else { throw ChatGPTOAuthError.malformedResponse }
            return ["Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account]
        }
        guard case let .apiKey(key)? = try await credentials.credential(for: scope), !key.isEmpty else {
            throw ChatGPTOAuthError.denied
        }
        return ["Authorization": "Bearer \(key)"]
    }

    func makeClient(configuration: NativeAgentRuntime.Configuration) async throws -> any LLMClient {
        let headers = try await authorizationHeaders()
        let effort = configuration.effort.flatMap(ReasoningConfig.Effort.init(rawValue:))
        return ResponsesAPIClient(
            model: configuration.modelID,
            contextWindowSize: configuration.modelID.flatMap { contextWindows[$0] },
            baseURL: baseURL,
            additionalHeaders: { headers },
            reasoningConfig: effort.map { ReasoningConfig(effort: $0) },
            store: false
        )
    }

    func fetchModels() async throws -> [ConnectionModel] {
        let headers = try await authorizationHeaders()
        var request = URLRequest(url: Self.modelCatalogURL(baseURL: baseURL, kind: kind))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count <= 4_194_304 else {
            throw AgentConnectionError.unavailable("The model catalog could not be loaded. Reconnect this account and try again.")
        }
        let catalog = try Self.parseCatalog(data, kind: kind)
        contextWindows = catalog.windows
        guard !catalog.models.isEmpty else {
            throw AgentConnectionError.unavailable("This account returned no compatible models.")
        }
        return catalog.models
    }

    static func modelCatalogURL(baseURL: URL, kind: ConnectionKind) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        if kind == .chatGPT {
            components.queryItems = [.init(name: "client_version", value: chatGPTModelCatalogClientVersion)]
        }
        return components.url!
    }

    static func parseCatalog(_ data: Data, kind: ConnectionKind) throws -> (models: [ConnectionModel], windows: [String: Int]) {
        struct Level: Decodable { let effort: String }
        struct Model: Decodable {
            let slug: String; let display_name: String?; let default_reasoning_level: String?
            let supported_reasoning_levels: [Level]?; let visibility: String?; let context_window: Int?
        }
        struct Catalog: Decodable { let models: [Model] }
        struct APIModel: Decodable { let id: String }
        struct APIList: Decodable { let data: [APIModel] }
        var windows: [String: Int] = [:]
        let models: [ConnectionModel]
        if kind == .chatGPT {
            models = try JSONDecoder().decode(Catalog.self, from: data).models
                .filter { !$0.slug.isEmpty && ($0.visibility == nil || $0.visibility == "list") }
                .map { model in
                    if let size = model.context_window, size > 0 { windows[model.slug] = size }
                    let efforts = (model.supported_reasoning_levels ?? []).map(\.effort)
                        .filter { ReasoningConfig.Effort(rawValue: $0) != nil }
                    return ConnectionModel(id: model.slug, displayName: model.display_name ?? model.slug,
                        isDefault: false, supportedReasoningEfforts: efforts,
                        defaultReasoningEffort: model.default_reasoning_level.flatMap { efforts.contains($0) ? $0 : nil })
                }
        } else {
            models = try JSONDecoder().decode(APIList.self, from: data).data.filter {
                let id = $0.id.lowercased()
                return (id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")) &&
                    !["embed", "audio", "realtime", "instruct", "image", "transcrib"].contains(where: id.contains)
            }.map { ConnectionModel(id: $0.id, displayName: $0.id, isDefault: false) }
        }
        var seen = Set<String>()
        return (models.filter { seen.insert($0.id).inserted }.sorted { $0.displayName < $1.displayName }, windows)
    }
}
