import CryptoKit
import Foundation

public enum ProjectCapability: String, Codable, CaseIterable, Sendable {
    case developmentCommands
    case computerUse
}

public struct ProjectCapabilityRequest: Sendable, Equatable {
    public let capability: ProjectCapability
    public let reason: String
    public init(capability: ProjectCapability, reason: String) { self.capability = capability; self.reason = reason }
}

public actor ProjectCapabilityStore {
    /// Several short-lived stores can address one project (runtime and Workspace). Serialize the
    /// read-modify-write cycle so one capability toggle cannot discard another in this process.
    private static let storageLock = NSLock()
    private let url: URL
    public init(projectURL: URL, applicationSupportURL: URL? = nil) {
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let id = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = applicationSupportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("FSCode/project-capabilities/\(id).json")
    }
    public func isEnabled(_ capability: ProjectCapability) -> Bool {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return (try? load())?[capability.rawValue] ?? false
    }
    public func setEnabled(_ capability: ProjectCapability, enabled: Bool) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        var values = try load()
        values[capability.rawValue] = enabled
        try save(values)
    }
    private func load() throws -> [String: Bool] { guard FileManager.default.fileExists(atPath: url.path) else { return [:] }; guard let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { throw CocoaError(.fileReadCorruptFile) }; return values }
    private func save(_ values: [String: Bool]) throws { let dir = url.deletingLastPathComponent(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try JSONEncoder().encode(values).write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}
