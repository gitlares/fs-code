import CryptoKit
import Foundation
import Security

/// A stable project identifier supplied by the caller, plus the profile that
/// owns the credential. It intentionally does not derive identity from a path.
public struct ProjectCredentialScope: Hashable, Sendable {
    public let projectID: UUID?
    public let fallbackScope: String?
    public let profileID: UUID

    /// Production callers pass the durable library project identifier. Moving
    /// the folder keeps this scope stable; copying it into a new library entry
    /// receives a different identifier and remains isolated.
    public init(projectID: UUID, profileID: UUID) {
        self.projectID = projectID
        self.fallbackScope = nil
        self.profileID = profileID
    }

    /// Only for isolated previews/tests without a library project identifier.
    public init(fallbackScope: String, profileID: UUID) {
        self.projectID = nil
        self.fallbackScope = fallbackScope
        self.profileID = profileID
    }
}

public enum ProjectCredential: Sendable, Equatable {
    case apiKey(String)
    case chatGPT(ChatGPTOAuthTokens)
}

public struct ProjectCredentialSnapshot: Sendable, Equatable {
    public let credential: ProjectCredential?
    public let generation: UInt64
}

/// A typed secret store. Implementations must never serialize these records
/// into connection profile metadata or diagnostic output.
public protocol ProjectCredentialStore: Sendable {
    func credential(for scope: ProjectCredentialScope) async throws -> ProjectCredential?
    func snapshot(for scope: ProjectCredentialScope) async throws -> ProjectCredentialSnapshot
    func generation(for scope: ProjectCredentialScope) async -> UInt64
    func replace(_ credential: ProjectCredential, for scope: ProjectCredentialScope, ifGeneration: UInt64?) async throws -> Bool
    func removeCredential(for scope: ProjectCredentialScope) async throws
}

private struct KeychainCredentialRecord: Codable {
    enum Kind: String, Codable { case apiKey, chatGPT }
    let kind: Kind
    let apiKey: String?
    let accessToken: String?
    let idToken: String?
    let refreshToken: String?
    let expiresAt: Date?

    init(_ credential: ProjectCredential) {
        switch credential {
        case let .apiKey(value):
            kind = .apiKey; apiKey = value; accessToken = nil; idToken = nil; refreshToken = nil; expiresAt = nil
        case let .chatGPT(value):
            kind = .chatGPT; apiKey = nil
            accessToken = value.accessToken; idToken = value.idToken
            refreshToken = value.refreshToken; expiresAt = value.expiresAt
        }
    }

    var credential: ProjectCredential? {
        switch kind {
        case .apiKey: return apiKey.map(ProjectCredential.apiKey)
        case .chatGPT:
            guard let accessToken, let refreshToken else { return nil }
            return .chatGPT(ChatGPTOAuthTokens(
                accessToken: accessToken, idToken: idToken,
                refreshToken: refreshToken, expiresAt: expiresAt
            ))
        }
    }
}

/// Security Keychain implementation for credentials created by FS Editor.
/// Existing Codex homes/keyrings are deliberately outside this namespace.
public actor KeychainProjectCredentialStore: ProjectCredentialStore {
    public static let service = "FS Editor"
    private var generations: [ProjectCredentialScope: UInt64] = [:]

    public init() {}

    public func credential(for scope: ProjectCredentialScope) throws -> ProjectCredential? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account(for: scope),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? JSONDecoder().decode(KeychainCredentialRecord.self, from: data) else {
            throw ProjectCredentialStoreError.unavailable
        }
        return record.credential
    }

    public func generation(for scope: ProjectCredentialScope) -> UInt64 {
        generations[scope, default: 0]
    }

    public func snapshot(for scope: ProjectCredentialScope) throws -> ProjectCredentialSnapshot {
        ProjectCredentialSnapshot(
            credential: try credential(for: scope),
            generation: generations[scope, default: 0]
        )
    }

    public func replace(_ credential: ProjectCredential, for scope: ProjectCredentialScope, ifGeneration expected: UInt64?) throws -> Bool {
        let current = generations[scope, default: 0]
        guard expected == nil || expected == current else { return false }
        let data = try JSONEncoder().encode(KeychainCredentialRecord(credential))
        let account = account(for: scope)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw ProjectCredentialStoreError.unavailable }
        } else if update != errSecSuccess {
            throw ProjectCredentialStoreError.unavailable
        }
        generations[scope] = current &+ 1
        return true
    }

    public func removeCredential(for scope: ProjectCredentialScope) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account(for: scope)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProjectCredentialStoreError.unavailable
        }
        generations[scope, default: 0] &+= 1
    }

    private func account(for scope: ProjectCredentialScope) -> String {
        let project = scope.projectID?.uuidString ?? scope.fallbackScope ?? ""
        let material = Data("\(project)\u{1F}\(scope.profileID.uuidString)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProjectCredentialStoreError: Error, Sendable {
    case unavailable
}
