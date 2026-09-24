import Foundation

public struct ChatGPTOAuthTokens: Equatable, Sendable {
    public let accessToken: String
    public let idToken: String?
    public let refreshToken: String
    public let expiresAt: Date?

    public init(accessToken: String, idToken: String?, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct DeviceAuthorization: Equatable, Sendable {
    public let verificationURL: URL
    public let userCode: String
    public let deviceAuthID: String
    public let pollInterval: TimeInterval
}

public struct ChatGPTAccountMetadata: Equatable, Sendable {
    public let accountID: String?
    public let email: String?
    public let displayName: String?
    public let expiresAt: Date?
}

public enum ChatGPTOAuthError: Error, Sendable {
    case unavailable
    case denied
    case expired
    case malformedResponse
}

public actor ChatGPTOAuthClient {
    /// This public client ID matches Codex for compatibility today. It does not
    /// establish that FS Editor owns an independent client registration.
    public static let compatibilityClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public typealias HTTPExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let store: any ProjectCredentialStore
    private let execute: HTTPExecutor
    private let sleep: Sleeper
    private let now: @Sendable () -> Date
    private var refreshes: [ProjectCredentialScope: (id: UUID, task: Task<ChatGPTOAuthTokens, Error>)] = [:]

    public init(
        store: any ProjectCredentialStore,
        execute: HTTPExecutor? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleeper = { seconds in try await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.store = store
        self.execute = execute ?? { request in try await Self.liveExecute(request) }
        self.now = now
        self.sleep = sleep
    }

    public func startDeviceAuthorization() async throws -> DeviceAuthorization {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": Self.compatibilityClientID])
        let (data, response) = try await execute(request)
        guard (200...299).contains(response.statusCode) else { throw sanitized(response.statusCode) }
        struct Response: Decodable { let device_auth_id: String; let user_code: String; let interval: String? }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard !value.device_auth_id.isEmpty, !value.user_code.isEmpty else { throw ChatGPTOAuthError.malformedResponse }
        let interval = min(60, max(1, TimeInterval(value.interval ?? "") ?? 5))
        return DeviceAuthorization(
            verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
            userCode: value.user_code,
            deviceAuthID: value.device_auth_id,
            pollInterval: interval
        )
    }

    /// Starts the OAuth authorization-code flow on a loopback-only callback.
    /// The returned session must be retained until its code is exchanged or
    /// cancelled, because it owns the listener and PKCE verifier.
    public func startBrowserAuthorization() async throws -> BrowserAuthorizationSession {
        let state = try BrowserOAuth.randomURLSafeString(byteCount: 32)
        let verifier = try BrowserOAuth.randomURLSafeString(byteCount: 64)
        let listener = try LoopbackCallbackListener(expectedState: state)
        let challenge = BrowserOAuth.challenge(for: verifier)
        var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.compatibilityClientID),
            URLQueryItem(name: "redirect_uri", value: BrowserOAuth.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            listener.cancel()
            throw ChatGPTOAuthError.unavailable
        }
        return BrowserAuthorizationSession(authorizationURL: url, codeVerifier: verifier, listener: listener)
    }

    public func exchangeBrowserAuthorization(
        code: String,
        session: BrowserAuthorizationSession
    ) async throws -> ChatGPTOAuthTokens {
        guard !code.isEmpty else { throw ChatGPTOAuthError.denied }
        return try await exchange(
            authorizationCode: code,
            verifier: session.codeVerifier,
            redirectURI: BrowserOAuth.redirectURI
        )
    }

    public func pollAuthorization(_ device: DeviceAuthorization) async throws -> ChatGPTOAuthTokens {
        let deadline = now().addingTimeInterval(15 * 60)
        while now() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": device.deviceAuthID, "user_code": device.userCode
            ])
            let (data, response) = try await execute(request)
            if (200...299).contains(response.statusCode) {
                struct Response: Decodable { let authorization_code: String; let code_verifier: String }
                let code = try JSONDecoder().decode(Response.self, from: data)
                return try await exchange(
                    authorizationCode: code.authorization_code,
                    verifier: code.code_verifier,
                    redirectURI: "https://auth.openai.com/deviceauth/callback"
                )
            }
            guard response.statusCode == 403 || response.statusCode == 404 else { throw sanitized(response.statusCode) }
            try await sleep(min(device.pollInterval, max(0, deadline.timeIntervalSince(now()))))
        }
        throw ChatGPTOAuthError.expired
    }

    public func accessToken(for scope: ProjectCredentialScope) async throws -> String {
        let snapshot = try await store.snapshot(for: scope)
        guard case let .chatGPT(tokens)? = snapshot.credential else {
            throw ChatGPTOAuthError.denied
        }
        if let expiry = tokens.expiresAt, expiry > now().addingTimeInterval(60) { return tokens.accessToken }
        return try await refresh(tokens: tokens, generation: snapshot.generation, scope: scope).accessToken
    }

    public func store(_ tokens: ChatGPTOAuthTokens, for scope: ProjectCredentialScope) async throws {
        refreshes.removeValue(forKey: scope)?.task.cancel()
        _ = try await store.replace(.chatGPT(tokens), for: scope, ifGeneration: nil)
    }

    public func revoke(scope: ProjectCredentialScope) async throws {
        refreshes.removeValue(forKey: scope)?.task.cancel()
        try await store.removeCredential(for: scope)
    }

    public static func accountMetadata(from idToken: String?) -> ChatGPTAccountMetadata? {
        guard let idToken,
              idToken.split(separator: ".").count >= 2,
              let payload = idToken.split(separator: ".").dropFirst().first,
              let data = Data(base64URLEncoded: String(payload)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let expiry = (object["exp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return ChatGPTAccountMetadata(
            accountID: ((object["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String),
            email: object["email"] as? String,
            displayName: object["name"] as? String,
            expiresAt: expiry
        )
    }

    private func refresh(tokens: ChatGPTOAuthTokens, generation: UInt64, scope: ProjectCredentialScope) async throws -> ChatGPTOAuthTokens {
        if let refresh = refreshes[scope] { return try await refresh.task.value }
        let current = try await store.snapshot(for: scope)
        if let refresh = refreshes[scope] { return try await refresh.task.value }
        guard current.generation == generation else { throw ChatGPTOAuthError.denied }
        let id = UUID()
        let task = Task { [execute, store, now] () throws -> ChatGPTOAuthTokens in
            var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form([
                "grant_type": "refresh_token",
                "client_id": Self.compatibilityClientID,
                "refresh_token": tokens.refreshToken
            ]).data(using: .utf8)
            let (data, response) = try await execute(request)
            guard (200...299).contains(response.statusCode) else { throw sanitized(response.statusCode) }
            let refreshed = try Self.decodeTokens(data, fallback: tokens, now: now())
            guard try await store.replace(.chatGPT(refreshed), for: scope, ifGeneration: generation) else {
                throw ChatGPTOAuthError.denied
            }
            return refreshed
        }
        refreshes[scope] = (id, task)
        defer {
            if refreshes[scope]?.id == id { refreshes[scope] = nil }
        }
        return try await task.value
    }

    private func exchange(authorizationCode: String, verifier: String, redirectURI: String) async throws -> ChatGPTOAuthTokens {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            "grant_type": "authorization_code", "client_id": Self.compatibilityClientID,
            "redirect_uri": redirectURI,
            "code": authorizationCode, "code_verifier": verifier
        ]).data(using: .utf8)
        let (data, response) = try await execute(request)
        guard (200...299).contains(response.statusCode) else { throw sanitized(response.statusCode) }
        return try Self.decodeTokens(data, fallback: nil, now: now())
    }

    private static func decodeTokens(_ data: Data, fallback: ChatGPTOAuthTokens?, now: Date) throws -> ChatGPTOAuthTokens {
        struct Response: Decodable {
            let access_token: String; let id_token: String?; let refresh_token: String?; let expires_in: TimeInterval?
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard !value.access_token.isEmpty, let refresh = value.refresh_token ?? fallback?.refreshToken, !refresh.isEmpty else {
            throw ChatGPTOAuthError.malformedResponse
        }
        let expiry = value.expires_in.map { now.addingTimeInterval($0) } ?? accountMetadata(from: value.access_token)?.expiresAt
        return ChatGPTOAuthTokens(accessToken: value.access_token, idToken: value.id_token ?? fallback?.idToken, refreshToken: refresh, expiresAt: expiry)
    }

    private static func form(_ fields: [String: String]) -> String {
        fields.map { key, value in
            "\(key.urlQueryEncoded)=\(value.urlQueryEncoded)"
        }.sorted().joined(separator: "&")
    }

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func liveExecute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await liveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTOAuthError.unavailable }
        return (data, http)
    }
}

private func sanitized(_ status: Int) -> ChatGPTOAuthError {
    status == 401 || status == 403 ? .denied : .unavailable
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
