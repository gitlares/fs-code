import Foundation
import CoreFoundation

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var tags: [String]
    public var lastOpened: Date?
    public var isFavorite: Bool
    /// True when this installation could not create `.fscode/project.json`.
    public var configurationStoredLocally: Bool

    public init(id: UUID, name: String, path: String, bookmark: Data? = nil, tags: [String] = [], lastOpened: Date? = nil, isFavorite: Bool = false, configurationStoredLocally: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.tags = tags
        self.lastOpened = lastOpened
        self.isFavorite = isFavorite
        self.configurationStoredLocally = configurationStoredLocally
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, bookmark, tags, lastOpened, isFavorite, configurationStoredLocally }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastOpened = try values.decodeIfPresent(Date.self, forKey: .lastOpened)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        configurationStoredLocally = try values.decodeIfPresent(Bool.self, forKey: .configurationStoredLocally) ?? false
    }
}

public enum LibraryError: LocalizedError, Equatable {
    case notDirectory, duplicate, emptyName, missingProject, unsupportedVersion, invalidProjectConfiguration, unsupportedProjectConfiguration

    public var errorDescription: String? {
        switch self {
        case .notDirectory: "Choose an existing folder."
        case .duplicate: "This folder is already in the library."
        case .emptyName: "The name cannot be empty."
        case .missingProject: "The project is no longer in the library."
        case .unsupportedVersion: "The library uses an unsupported version. The file has not been modified."
        case .invalidProjectConfiguration: "The .fscode/project.json configuration is invalid. It has not been modified."
        case .unsupportedProjectConfiguration: "The project configuration uses an unsupported version. It has not been modified."
        }
    }
}

/// Native persistence adapter. Kept independent of AppKit to allow replacement by Rust.
public final class ProjectLibrary {
    private struct Document: Codable { var version = 1; var projects: [Project] }
    private struct ProjectConfiguration {
        let originalData: Data
        var object: [String: Any]
        var name: String
    }
    private enum ConfigurationBackup {
        case absent(URL)
        case existing(URL, Data)
    }

    public private(set) var projects: [Project] = []
    public let storageURL: URL
    private let fileManager: FileManager

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FS Code/projects.json")
        if fileManager.fileExists(atPath: self.storageURL.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.storageURL))
            guard document.version == 1 else { throw LibraryError.unsupportedVersion }
            projects = document.projects
        }
    }

    public func url(for project: Project) -> URL {
        if let bookmark = project.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) { return resolved }
        }
        return URL(fileURLWithPath: project.path)
    }

    public func isAvailable(_ project: Project) -> Bool { isDirectory(url(for: project)) }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    private func sameFolder(_ a: URL, _ b: URL) -> Bool {
        if canonical(a) == canonical(b) { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let first = try? a.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject
        let second = try? b.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject
        return first != nil && first == second
    }

    private func commit(_ values: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(projects: values))
        try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        projects = values
    }

    private func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func configurationURL(for directory: URL) -> URL {
        directory.appendingPathComponent(".fscode", isDirectory: true).appendingPathComponent("project.json")
    }

    private func readConfiguration(at directory: URL) throws -> ProjectConfiguration? {
        let url = configurationURL(for: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else { throw LibraryError.invalidProjectConfiguration }
        guard let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              version.intValue == 1
        else { throw LibraryError.unsupportedProjectConfiguration }
        guard let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidProjectConfiguration }
        return ProjectConfiguration(originalData: data, object: object, name: name)
    }

    /// Preserves unknown config keys and returns a backup for a failed library commit.
    private func writeConfiguration(at directory: URL, name: String, existing: ProjectConfiguration?) throws -> ConfigurationBackup {
        let url = configurationURL(for: directory)
        var object = existing?.object ?? [:]
        object["version"] = 1
        object["name"] = name
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let backup: ConfigurationBackup = existing.map { .existing(url, $0.originalData) } ?? .absent(url)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return backup
    }

    private func rollbackConfiguration(_ backup: ConfigurationBackup) {
        switch backup {
        case .absent(let url): try? fileManager.removeItem(at: url)
        case .existing(let url, let data): try? data.write(to: url, options: .atomic)
        }
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code)
    }

    /// Reads a valid existing project config so the add dialog can prefill its name.
    public func suggestedName(for url: URL) throws -> String {
        let directory = canonical(url)
        guard isDirectory(directory) else { throw LibraryError.notDirectory }
        return try readConfiguration(at: directory)?.name ?? directory.lastPathComponent
    }

    /// Adds an existing folder. `name` is a display name and never renames the folder.
    @discardableResult public func add(_ url: URL, named name: String? = nil) throws -> Project {
        let directory = canonical(url)
        guard isDirectory(directory) else { throw LibraryError.notDirectory }
        guard !projects.contains(where: { sameFolder(self.url(for: $0), directory) }) else { throw LibraryError.duplicate }
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedName, requestedName.isEmpty { throw LibraryError.emptyName }
        let existing = try readConfiguration(at: directory)
        let displayName = requestedName ?? existing?.name ?? directory.lastPathComponent
        var localOnly = false
        var backup: ConfigurationBackup?
        do { backup = try writeConfiguration(at: directory, name: displayName, existing: existing) }
        catch {
            guard existing == nil && isPermissionError(error) else { throw error }
            localOnly = true
        }
        let project = Project(id: UUID(), name: displayName, path: directory.path, bookmark: bookmark(directory), configurationStoredLocally: localOnly)
        do { try commit(projects + [project]) }
        catch { if let backup { rollbackConfiguration(backup) }; throw error }
        return project
    }

    /// Backwards-compatible convenience API using the folder name.
    @discardableResult public func add(_ url: URL) throws -> Project { try add(url, named: nil) }

    public func update(_ project: Project) throws {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.emptyName }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw LibraryError.missingProject }
        let previous = projects[index]
        var nextProject = project
        nextProject.name = name
        var backup: ConfigurationBackup?
        let directory = canonical(url(for: previous))
        if previous.name != name && isDirectory(directory) {
            let existing = try readConfiguration(at: directory)
            do { backup = try writeConfiguration(at: directory, name: name, existing: existing); nextProject.configurationStoredLocally = false }
            catch {
                guard existing == nil && isPermissionError(error) else { throw error }
                nextProject.configurationStoredLocally = true
            }
        }
        var next = projects
        next[index] = nextProject
        do { try commit(next) }
        catch { if let backup { rollbackConfiguration(backup) }; throw error }
    }

    public func remove(_ id: UUID) throws { try commit(projects.filter { $0.id != id }) }

    public func relocate(_ project: Project, to url: URL) throws {
        let directory = canonical(url)
        guard isDirectory(directory) else { throw LibraryError.notDirectory }
        guard !projects.contains(where: { $0.id != project.id && sameFolder(self.url(for: $0), directory) }) else { throw LibraryError.duplicate }
        var next = project
        next.path = directory.path
        next.bookmark = bookmark(directory)
        try update(next)
    }

    public func markOpened(_ project: Project) throws {
        var next = project
        let resolved = url(for: project)
        guard isDirectory(resolved) else { throw LibraryError.notDirectory }
        if let configuration = try readConfiguration(at: canonical(resolved)) {
            next.name = configuration.name
            next.configurationStoredLocally = false
        }
        next.path = resolved.path
        next.bookmark = bookmark(resolved)
        next.lastOpened = Date()
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw LibraryError.missingProject }
        var values = projects
        values[index] = next
        try commit(values)
    }

    public func search(_ query: String, favoritesOnly: Bool = false) -> [Project] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter {
            (!favoritesOnly || $0.isFavorite) && (query.isEmpty || ([$0.name, url(for: $0).path] + $0.tags).contains { $0.localizedStandardContains(query) })
        }.sorted {
            let firstDate = $0.lastOpened ?? .distantPast
            let secondDate = $1.lastOpened ?? .distantPast
            if firstDate != secondDate { return firstDate > secondDate }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
