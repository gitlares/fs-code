import Foundation

public enum TodoRelevance: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
}

public struct TodoComment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Describes how a TODO entered the project list.
///
/// The manual case is the implicit value for documents written before inline
/// TODO provenance was stored. A legacy linkedFilePath therefore never becomes
/// an inline source by decoding alone.
public enum ProjectTodoOrigin: String, Codable, Equatable, Sendable {
    case manual
    case inlineComment
}

public struct TodoSourceLocation: Codable, Equatable, Sendable {
    public var line: Int
    public var column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}

public struct ProjectTodo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var description: String
    public var comments: [TodoComment]
    public var isCompleted: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var relevance: TodoRelevance
    /// A path relative to the project root. The referenced file may be absent.
    public var linkedFilePath: String?
    /// Provenance for a linked source. Legacy and newly created TODOs default to manual.
    public var origin: ProjectTodoOrigin
    /// Location of the inline comment that produced this TODO, when available.
    public var sourceLocation: TodoSourceLocation?

    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        comments: [TodoComment] = [],
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        relevance: TodoRelevance = .normal,
        linkedFilePath: String? = nil,
        origin: ProjectTodoOrigin = .manual,
        sourceLocation: TodoSourceLocation? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.comments = comments
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.relevance = relevance
        self.linkedFilePath = linkedFilePath
        self.origin = origin
        self.sourceLocation = sourceLocation
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, comments, isCompleted, createdAt, updatedAt, relevance, linkedFilePath, origin, sourceLocation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        description = try values.decode(String.self, forKey: .description)
        comments = try values.decode([TodoComment].self, forKey: .comments)
        isCompleted = try values.decode(Bool.self, forKey: .isCompleted)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        relevance = try values.decodeIfPresent(TodoRelevance.self, forKey: .relevance) ?? .normal
        linkedFilePath = try values.decodeIfPresent(String.self, forKey: .linkedFilePath)
        origin = try values.decodeIfPresent(ProjectTodoOrigin.self, forKey: .origin) ?? .manual
        sourceLocation = try values.decodeIfPresent(TodoSourceLocation.self, forKey: .sourceLocation)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(comments, forKey: .comments)
        try values.encode(isCompleted, forKey: .isCompleted)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(relevance, forKey: .relevance)
        try values.encodeIfPresent(linkedFilePath, forKey: .linkedFilePath)
        // Keep the legacy JSON shape for manual TODOs. Inline provenance is
        // emitted only when a future scanner has supplied it explicitly.
        if origin != .manual { try values.encode(origin, forKey: .origin) }
        try values.encodeIfPresent(sourceLocation, forKey: .sourceLocation)
    }
}

public enum ProjectTodosError: LocalizedError, Equatable {
    case invalidStorage
    case unsupportedVersion
    case externalChangeConflict
    case emptyTitle
    case emptyComment
    case duplicateTodoID
    case duplicateCommentID
    case invalidLinkedFilePath
    case invalidInlineSource

    public var errorDescription: String? {
        switch self {
        case .invalidStorage:
            "The project TODO file is invalid. It has not been modified."
        case .unsupportedVersion:
            "The project TODO file uses an unsupported version. It has not been modified."
        case .externalChangeConflict:
            "The project TODO file changed outside this window. Reload it before saving."
        case .emptyTitle:
            "A TODO title cannot be empty."
        case .emptyComment:
            "A TODO comment cannot be empty."
        case .duplicateTodoID:
            "The project TODO file contains duplicate TODO IDs. It has not been modified."
        case .duplicateCommentID:
            "The project TODO file contains duplicate comment IDs. It has not been modified."
        case .invalidLinkedFilePath:
            "A TODO file link must remain within the project folder."
        case .invalidInlineSource:
            "An inline TODO link requires a project-relative file and a positive source line."
        }
    }
}

/// Small synchronous store for TODOs belonging to one project folder.
public final class ProjectTodos {
    private struct Document: Codable {
        var version: Int
        var items: [ProjectTodo]
    }

    public private(set) var items: [ProjectTodo]
    public let storageURL: URL
    private let projectURL: URL

    private let fileManager: FileManager
    private var lastReadData: Data?

    public init(projectURL: URL) throws {
        fileManager = .default
        self.projectURL = projectURL.standardizedFileURL
        storageURL = self.projectURL
            .appendingPathComponent(".fscode", isDirectory: true)
            .appendingPathComponent("todos.json")
        items = []
        try reload()
    }

    public func reload() throws {
        let data = try currentData()
        guard let data else {
            items = []
            lastReadData = nil
            return
        }

        let document = try decode(data)
        items = document.items
        lastReadData = data
    }

    public func save(_ todo: ProjectTodo) throws {
        let todo = try validated(todo)
        try ensureNoExternalChange()

        var next = items
        if let index = next.firstIndex(where: { $0.id == todo.id }) {
            var updated = todo
            updated.createdAt = next[index].createdAt
            updated.updatedAt = Date()
            next[index] = updated
        } else {
            var inserted = todo
            inserted.updatedAt = Date()
            next.append(inserted)
        }
        try commit(next)
    }

    public func remove(_ id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { return }
        try ensureNoExternalChange()
        try commit(items.filter { $0.id != id })
    }

    /// Returns the linked file only when its relative path is still confined to this project.
    public func linkedFileURL(for todo: ProjectTodo) throws -> URL? {
        guard let linkedFilePath = todo.linkedFilePath else { return nil }
        return try validatedLinkedFileURL(for: linkedFilePath)
    }

    /// Returns a source location only for TODOs explicitly created by an
    /// inline-comment scanner. Legacy/manual links are intentionally ignored.
    public func inlineSource(for todo: ProjectTodo) throws -> (url: URL, location: TodoSourceLocation)? {
        guard todo.origin == .inlineComment,
              let sourceLocation = todo.sourceLocation,
              sourceLocation.line > 0,
              let url = try linkedFileURL(for: todo) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        return (url, sourceLocation)
    }

    private func currentData() throws -> Data? {
        guard fileManager.fileExists(atPath: storageURL.path) else { return nil }
        return try Data(contentsOf: storageURL)
    }

    private func decode(_ data: Data) throws -> Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let document = try decoder.decode(Document.self, from: data)
            guard document.version == 1 else { throw ProjectTodosError.unsupportedVersion }
            guard Set(document.items.map(\.id)).count == document.items.count else { throw ProjectTodosError.duplicateTodoID }
            for todo in document.items {
                _ = try validated(todo)
                guard Set(todo.comments.map(\.id)).count == todo.comments.count else { throw ProjectTodosError.duplicateCommentID }
            }
            return document
        } catch let error as ProjectTodosError {
            throw error
        } catch {
            throw ProjectTodosError.invalidStorage
        }
    }

    private func validated(_ todo: ProjectTodo) throws -> ProjectTodo {
        var normalized = todo
        normalized.title = normalized.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.title.isEmpty else { throw ProjectTodosError.emptyTitle }
        for index in normalized.comments.indices {
            normalized.comments[index].text = normalized.comments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.comments[index].text.isEmpty else { throw ProjectTodosError.emptyComment }
        }
        guard Set(normalized.comments.map(\.id)).count == normalized.comments.count else { throw ProjectTodosError.duplicateCommentID }
        if let linkedFilePath = normalized.linkedFilePath {
            _ = try validatedLinkedFileURL(for: linkedFilePath)
        }
        if normalized.origin == .inlineComment {
            guard normalized.linkedFilePath != nil,
                  let location = normalized.sourceLocation,
                  location.line > 0 else { throw ProjectTodosError.invalidInlineSource }
        }
        return normalized
    }

    private func validatedLinkedFileURL(for path: String) throws -> URL {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else {
            throw ProjectTodosError.invalidLinkedFilePath
        }

        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        var resolvedPath = root
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                resolvedPath = resolvedPath.deletingLastPathComponent()
            default:
                resolvedPath = resolvedPath.appendingPathComponent(String(component))
            }

            // Resolving component by component catches an existing symlink even
            // when the linked file beneath it does not exist yet.
            resolvedPath = resolvedPath.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolvedPath, of: root) else {
                throw ProjectTodosError.invalidLinkedFilePath
            }
        }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard isDescendant(candidate, of: root) else { throw ProjectTodosError.invalidLinkedFilePath }
        return candidate
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private func ensureNoExternalChange() throws {
        guard try currentData() == lastReadData else { throw ProjectTodosError.externalChangeConflict }
    }

    private func commit(_ values: [ProjectTodo]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, items: values))
        try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        items = values
        lastReadData = data
    }
}
