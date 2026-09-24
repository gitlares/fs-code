import Foundation

public struct ContextScanConfiguration: Sendable {
    public var maximumVisitedFiles: Int
    public var maximumDepth: Int
    public var maximumRuleBytes: Int
    public var maximumTotalRuleBytes: Int
    public var maximumRuleCount: Int

    public init(
        maximumVisitedFiles: Int = 20_000,
        maximumDepth: Int = 64,
        maximumRuleBytes: Int = 1_048_576,
        maximumTotalRuleBytes: Int = 16 * 1_024 * 1_024,
        maximumRuleCount: Int = 512
    ) {
        self.maximumVisitedFiles = max(1, maximumVisitedFiles)
        self.maximumDepth = max(1, maximumDepth)
        self.maximumRuleBytes = max(1, maximumRuleBytes)
        self.maximumTotalRuleBytes = max(1, maximumTotalRuleBytes)
        self.maximumRuleCount = max(1, maximumRuleCount)
    }
}

public struct ContextStoreConfiguration: Sendable {
    public let projectURL: URL
    public let globalStoreURL: URL
    public let scan: ContextScanConfiguration

    public init(
        projectURL: URL,
        globalStoreURL: URL? = nil,
        scan: ContextScanConfiguration = .init()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.globalStoreURL = (
            globalStoreURL ?? Self.defaultGlobalStoreURL()
        ).standardizedFileURL
        self.scan = scan
    }

    public static func defaultGlobalStoreURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport.appendingPathComponent("FS Code/context", isDirectory: true)
    }
}

public enum ContextStoreError: Error, LocalizedError, Sendable {
    case stale
    case invalidTarget
    case invalidName
    case missingRule
    case corruptManifest
    case duplicateIdentifier
    case readOnlyExternal
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .stale: "The context changed outside FS Code."
        case .invalidTarget: "The context target is invalid or escapes the project."
        case .invalidName: "The context name cannot be empty."
        case .missingRule: "The context no longer exists."
        case .corruptManifest: "The context manifest is invalid. It was not overwritten."
        case .duplicateIdentifier: "The context identifier collides with another stored context."
        case .readOnlyExternal: "External context files are read-only through the context store."
        case .invalidEncoding: "The context file is not valid UTF-8."
        }
    }
}

public actor ContextStore {
    private struct Manifest: Codable {
        var version: Int
        var rules: [RuleRecord]
        var externalActivations: [String: Bool]

        init(version: Int = 1, rules: [RuleRecord] = [], externalActivations: [String: Bool] = [:]) {
            self.version = version
            self.rules = rules
            self.externalActivations = externalActivations
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case rules
            case externalActivations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            rules = try container.decodeIfPresent([RuleRecord].self, forKey: .rules) ?? []
            externalActivations = try container.decodeIfPresent([String: Bool].self, forKey: .externalActivations) ?? [:]
        }
    }

    private struct RuleRecord: Codable, Equatable {
        let id: UUID
        var name: String
        var scope: ContextScope
        var target: String?
        var enabled: Bool
        var priority: Int
    }

    private enum StoreKind {
        case project
        case global
    }

    public let configuration: ContextStoreConfiguration

    public init(configuration: ContextStoreConfiguration) {
        self.configuration = configuration
    }

    /// Loads owned rules from their live Markdown files and merges a fresh,
    /// deterministic workspace discovery. This method never creates files.
    public func load() throws -> ContextCatalogSnapshot {
        let projectManifest = try readManifest(at: projectManifestURL)
        let globalManifest = try readManifest(at: globalManifestURL)
        try validateNoCollisions(projectManifest: projectManifest, globalManifest: globalManifest)

        var diagnostics: [ContextDiagnostic] = []
        var budget = ContextRuleBudget(configuration: configuration.scan)
        let globalRules = try loadOwned(
            manifest: globalManifest,
            directory: configuration.globalStoreURL,
            expectedKind: .global,
            diagnostics: &diagnostics,
            budget: &budget
        )
        let projectRules = try loadOwned(
            manifest: projectManifest,
            directory: projectContextDirectory,
            expectedKind: .project,
            diagnostics: &diagnostics,
            budget: &budget
        )
        let external = ContextExternalScanner(
            projectURL: configuration.projectURL,
            configuration: configuration.scan,
            activations: projectManifest.externalActivations,
            excludedDirectories: [configuration.globalStoreURL],
            initialBudget: budget
        ).scan()
        diagnostics.append(contentsOf: external.diagnostics)

        let allRules = (globalRules + projectRules + external.rules).sorted(by: catalogOrder)
        return .init(rules: allRules, diagnostics: stableUnique(diagnostics))
    }

    /// Scans only external files. Activation state is read from the project
    /// manifest; a corrupt manifest fails closed and is never replaced.
    public func scanExternal() throws -> ContextCatalogSnapshot {
        let projectManifest = try readManifest(at: projectManifestURL)
        return ContextExternalScanner(
            projectURL: configuration.projectURL,
            configuration: configuration.scan,
            activations: projectManifest.externalActivations,
            excludedDirectories: [configuration.globalStoreURL]
        ).scan()
    }

    /// Resolves a fresh catalog. UI callers that already refreshed a catalog can
    /// use `resolve(snapshot:paths:)` to avoid another recursive scan.
    public func resolve(paths: [URL]) throws -> ContextResolution {
        let snapshot = try load()
        return resolve(snapshot: snapshot, paths: paths)
    }

    public func resolve(snapshot: ContextCatalogSnapshot, paths: [URL]) -> ContextResolution {
        ContextResolver().resolve(snapshot: snapshot, projectURL: configuration.projectURL, paths: paths)
    }

    public func create(
        name: String,
        scope: ContextScope,
        target: String? = nil,
        priority: Int = 0,
        content: String
    ) throws -> ContextRule {
        let cleanName = try validatedName(name)
        let cleanTarget = try validatedTarget(scope: scope, target: target)
        let destination: StoreKind = scope == .global ? .global : .project

        var projectManifest = try readManifest(at: projectManifestURL)
        var globalManifest = try readManifest(at: globalManifestURL)
        try validateNoCollisions(projectManifest: projectManifest, globalManifest: globalManifest)

        let existing = Set((projectManifest.rules + globalManifest.rules).map(\.id))
        var id = UUID()
        while existing.contains(id) { id = UUID() }

        let record = RuleRecord(
            id: id,
            name: cleanName,
            scope: scope,
            target: cleanTarget,
            enabled: true,
            priority: priority
        )
        let directory = directory(for: destination)
        try validateStoreDirectory(destination)
        let markdownURL = markdownURL(for: id, in: directory)
        try ensureOwnedURL(markdownURL, in: directory)
        guard content.lengthOfBytes(using: .utf8) <= configuration.scan.maximumRuleBytes else {
            throw ContextStoreError.invalidTarget
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: markdownURL, options: .atomic)

        do {
            switch destination {
            case .project:
                projectManifest.rules.append(record)
                try save(projectManifest, to: projectManifestURL)
            case .global:
                globalManifest.rules.append(record)
                try save(globalManifest, to: globalManifestURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: markdownURL)
            throw error
        }

        return ownedRule(record: record, url: markdownURL, content: content)
    }

    /// Content-only update that deliberately preserves all metadata.
    public func update(id: UUID, expectedHash: String, content: String) throws -> ContextRule {
        let located = try locateOwned(id: id)
        return try update(
            id: id,
            expectedHash: expectedHash,
            name: located.record.name,
            scope: located.record.scope,
            target: located.record.target,
            priority: located.record.priority,
            enabled: located.record.enabled,
            content: content
        )
    }

    public func update(
        id: UUID,
        expectedHash: String,
        name: String,
        scope: ContextScope,
        target: String?,
        priority: Int,
        enabled: Bool,
        content: String
    ) throws -> ContextRule {
        let cleanName = try validatedName(name)
        let cleanTarget = try validatedTarget(scope: scope, target: target)
        let located = try locateOwned(id: id)
        try validateStoreDirectory(located.kind)
        let sourceURL = markdownURL(for: id, in: directory(for: located.kind))
        try ensureOwnedURL(sourceURL, in: directory(for: located.kind))
        let oldData = try liveData(at: sourceURL)
        guard ContextResolver.hash(oldData) == expectedHash else { throw ContextStoreError.stale }
        guard content.lengthOfBytes(using: .utf8) <= configuration.scan.maximumRuleBytes else {
            throw ContextStoreError.invalidTarget
        }

        let destination: StoreKind = scope == .global ? .global : .project
        try validateStoreDirectory(destination)
        let destinationDirectory = directory(for: destination)
        let destinationURL = markdownURL(for: id, in: destinationDirectory)
        try ensureOwnedURL(destinationURL, in: destinationDirectory)

        var projectManifest = located.projectManifest
        var globalManifest = located.globalManifest
        removeRecord(id: id, from: &projectManifest)
        removeRecord(id: id, from: &globalManifest)
        let newRecord = RuleRecord(
            id: id,
            name: cleanName,
            scope: scope,
            target: cleanTarget,
            enabled: enabled,
            priority: priority
        )
        switch destination {
        case .project: projectManifest.rules.append(newRecord)
        case .global: globalManifest.rules.append(newRecord)
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let newData = Data(content.utf8)
        try newData.write(to: destinationURL, options: .atomic)
        do {
            if located.kind == destination {
                switch destination {
                case .project: try save(projectManifest, to: projectManifestURL)
                case .global: try save(globalManifest, to: globalManifestURL)
                }
            } else {
                let oldProjectManifestData = try existingData(at: projectManifestURL, maximumBytes: maximumManifestBytes)
                let oldGlobalManifestData = try existingData(at: globalManifestURL, maximumBytes: maximumManifestBytes)
                do {
                    try save(projectManifest, to: projectManifestURL)
                    try save(globalManifest, to: globalManifestURL)
                } catch {
                    try? restore(oldProjectManifestData, at: projectManifestURL)
                    try? restore(oldGlobalManifestData, at: globalManifestURL)
                    throw error
                }
            }
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        } catch {
            if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
                try? oldData.write(to: sourceURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
        return ownedRule(record: newRecord, url: destinationURL, content: content)
    }

    public func rename(id: UUID, name: String) throws -> ContextRule {
        let cleanName = try validatedName(name)
        var located = try locateOwned(id: id)
        try validateStoreDirectory(located.kind)
        let url = markdownURL(for: id, in: directory(for: located.kind))
        try ensureOwnedURL(url, in: directory(for: located.kind))
        let content = try liveString(at: url)
        switch located.kind {
        case .project:
            located.projectManifest.rules[located.index].name = cleanName
            try save(located.projectManifest, to: projectManifestURL)
            return ownedRule(record: located.projectManifest.rules[located.index], url: url, content: content)
        case .global:
            located.globalManifest.rules[located.index].name = cleanName
            try save(located.globalManifest, to: globalManifestURL)
            return ownedRule(record: located.globalManifest.rules[located.index], url: url, content: content)
        }
    }

    public func remove(id: UUID) throws {
        var located = try locateOwned(id: id)
        let directory = directory(for: located.kind)
        try validateStoreDirectory(located.kind)
        let url = markdownURL(for: id, in: directory)
        try ensureOwnedURL(url, in: directory)

        let temporaryURL = directory.appendingPathComponent(".\(id.uuidString).deleting")
        let hadFile = FileManager.default.fileExists(atPath: url.path)
        if hadFile {
            try? FileManager.default.removeItem(at: temporaryURL)
            try FileManager.default.moveItem(at: url, to: temporaryURL)
        }

        do {
            switch located.kind {
            case .project:
                located.projectManifest.rules.remove(at: located.index)
                try save(located.projectManifest, to: projectManifestURL)
            case .global:
                located.globalManifest.rules.remove(at: located.index)
                try save(located.globalManifest, to: globalManifestURL)
            }
            if hadFile { try? FileManager.default.removeItem(at: temporaryURL) }
        } catch {
            if hadFile { try? FileManager.default.moveItem(at: temporaryURL, to: url) }
            throw error
        }
    }

    public func setActivation(id: UUID, enabled: Bool) throws -> ContextRule {
        do {
            var located = try locateOwned(id: id)
            try validateStoreDirectory(located.kind)
            let url = markdownURL(for: id, in: directory(for: located.kind))
            try ensureOwnedURL(url, in: directory(for: located.kind))
            let content = try liveString(at: url)
            switch located.kind {
            case .project:
                located.projectManifest.rules[located.index].enabled = enabled
                try save(located.projectManifest, to: projectManifestURL)
                return ownedRule(record: located.projectManifest.rules[located.index], url: url, content: content)
            case .global:
                located.globalManifest.rules[located.index].enabled = enabled
                try save(located.globalManifest, to: globalManifestURL)
                return ownedRule(record: located.globalManifest.rules[located.index], url: url, content: content)
            }
        } catch ContextStoreError.missingRule {
            // The stable external identifier is resolved below.
        }

        var manifest = try readManifest(at: projectManifestURL)
        let scan = ContextExternalScanner(
            projectURL: configuration.projectURL,
            configuration: configuration.scan,
            activations: manifest.externalActivations,
            excludedDirectories: [configuration.globalStoreURL]
        ).scan()
        guard var rule = scan.rules.first(where: { $0.id == id }) else {
            throw ContextStoreError.missingRule
        }
        let key = try externalActivationKey(for: rule)
        manifest.externalActivations[key] = enabled
        try save(manifest, to: projectManifestURL)
        rule.enabled = enabled
        return rule
    }

    private var projectContextDirectory: URL {
        configuration.projectURL.appendingPathComponent(".fs/context", isDirectory: true)
    }

    private var projectManifestURL: URL {
        projectContextDirectory.appendingPathComponent("manifest.json")
    }

    private var globalManifestURL: URL {
        configuration.globalStoreURL.appendingPathComponent("manifest.json")
    }

    private var maximumManifestBytes: Int { 4 * 1_024 * 1_024 }

    private func directory(for kind: StoreKind) -> URL {
        kind == .project ? projectContextDirectory : configuration.globalStoreURL
    }

    private func markdownURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".md")
    }

    private func readManifest(at url: URL) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return Manifest() }
        do {
            if url.standardizedFileURL == projectManifestURL.standardizedFileURL {
                try validateStoreDirectory(.project)
                try ensureOwnedURL(url, in: projectContextDirectory)
            } else if url.standardizedFileURL == globalManifestURL.standardizedFileURL {
                try validateStoreDirectory(.global)
                try ensureOwnedURL(url, in: configuration.globalStoreURL)
            }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maximumManifestBytes
            else {
                throw ContextStoreError.corruptManifest
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumManifestBytes else { throw ContextStoreError.corruptManifest }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1,
                  Set(manifest.rules.map(\.id)).count == manifest.rules.count
            else {
                throw ContextStoreError.corruptManifest
            }
            return manifest
        } catch let error as ContextStoreError {
            throw error
        } catch {
            throw ContextStoreError.corruptManifest
        }
    }

    private func save(_ manifest: Manifest, to url: URL) throws {
        guard manifest.version == 1,
              Set(manifest.rules.map(\.id)).count == manifest.rules.count
        else {
            throw ContextStoreError.corruptManifest
        }
        if url.standardizedFileURL == projectManifestURL.standardizedFileURL {
            try validateStoreDirectory(.project)
            try ensureOwnedURL(url, in: projectContextDirectory)
        } else {
            try validateStoreDirectory(.global)
            try ensureOwnedURL(url, in: configuration.globalStoreURL)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func loadOwned(
        manifest: Manifest,
        directory: URL,
        expectedKind: StoreKind,
        diagnostics: inout [ContextDiagnostic],
        budget: inout ContextRuleBudget
    ) throws -> [ContextRule] {
        var rules: [ContextRule] = []
        for record in manifest.rules.sorted(by: recordOrder) {
            let url = markdownURL(for: record.id, in: directory)
            let byteCount = ownedByteCountIfSafelyKnown(at: url)
            guard budget.reserve(byteCount: byteCount, source: "owned context \(record.id.uuidString)", diagnostics: &diagnostics) else {
                break
            }
            let correctScope = expectedKind == .global ? record.scope == .global : record.scope != .global
            let validMetadata: Bool
            do {
                _ = try validatedName(record.name)
                _ = try validatedTarget(scope: record.scope, target: record.target)
                validMetadata = true
            } catch {
                validMetadata = false
            }
            guard correctScope, validMetadata else {
                let diagnostic = ContextDiagnostic(.invalidManifest, "Invalid metadata for owned context \(record.id.uuidString).")
                diagnostics.append(diagnostic)
                rules.append(
                    .init(
                        id: record.id,
                        name: record.name,
                        url: markdownURL(for: record.id, in: directory),
                        origin: .fsCode,
                        scope: record.scope,
                        target: record.target,
                        enabled: false,
                        priority: record.priority,
                        content: "",
                        hash: ContextResolver.hash(""),
                        diagnostics: [diagnostic],
                        applicability: .unsupported,
                        applicabilityReason: diagnostic.message
                    )
                )
                continue
            }

            do {
                try ensureOwnedURL(url, in: directory)
                let content = try liveString(at: url)
                rules.append(ownedRule(record: record, url: url, content: content))
            } catch {
                let diagnostic = ContextDiagnostic(.missing, "Owned context file is missing or unreadable: \(url.path)")
                diagnostics.append(diagnostic)
                rules.append(
                    .init(
                        id: record.id,
                        name: record.name,
                        url: url,
                        origin: .fsCode,
                        scope: record.scope,
                        target: record.target,
                        enabled: false,
                        priority: record.priority,
                        content: "",
                        hash: ContextResolver.hash(""),
                        diagnostics: [diagnostic],
                        applicability: .unsupported,
                        applicabilityReason: diagnostic.message
                    )
                )
            }
        }
        return rules
    }

    private func ownedByteCountIfSafelyKnown(at url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= configuration.scan.maximumRuleBytes
        else {
            return 0
        }
        return size
    }

    private func ownedRule(record: RuleRecord, url: URL, content: String) -> ContextRule {
        .init(
            id: record.id,
            name: record.name,
            url: url,
            origin: .fsCode,
            provider: .fsCode,
            scope: record.scope,
            target: record.target,
            enabled: record.enabled,
            priority: record.priority,
            content: content,
            hash: ContextResolver.hash(content)
        )
    }

    private func locateOwned(id: UUID) throws -> (
        kind: StoreKind,
        index: Int,
        record: RuleRecord,
        projectManifest: Manifest,
        globalManifest: Manifest
    ) {
        let project = try readManifest(at: projectManifestURL)
        let global = try readManifest(at: globalManifestURL)
        try validateNoCollisions(projectManifest: project, globalManifest: global)
        if let index = project.rules.firstIndex(where: { $0.id == id }) {
            return (.project, index, project.rules[index], project, global)
        }
        if let index = global.rules.firstIndex(where: { $0.id == id }) {
            return (.global, index, global.rules[index], project, global)
        }
        throw ContextStoreError.missingRule
    }

    private func validateNoCollisions(projectManifest: Manifest, globalManifest: Manifest) throws {
        let projectIDs = Set(projectManifest.rules.map(\.id))
        guard projectIDs.isDisjoint(with: Set(globalManifest.rules.map(\.id))) else {
            throw ContextStoreError.corruptManifest
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ContextStoreError.invalidName }
        return cleaned
    }

    private func validatedTarget(scope: ContextScope, target: String?) throws -> String? {
        switch scope {
        case .global, .project:
            guard target == nil || target?.isEmpty == true else { throw ContextStoreError.invalidTarget }
            return nil
        case .folder, .file:
            guard let target else { throw ContextStoreError.invalidTarget }
            let normalized = normalizeRelative(target)
            guard !normalized.isEmpty,
                  !target.hasPrefix("/"),
                  !target.contains("\\"),
                  !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else {
                throw ContextStoreError.invalidTarget
            }
            let candidate = configuration.projectURL.appendingPathComponent(normalized)
            guard ContextResolver.isContained(candidate, in: configuration.projectURL) else {
                throw ContextStoreError.invalidTarget
            }
            return normalized
        case .glob:
            guard let target, ContextResolver.validateGlob(target) == nil else {
                throw ContextStoreError.invalidTarget
            }
            return normalizeRelative(target)
        case .external:
            throw ContextStoreError.invalidTarget
        }
    }

    private func ensureOwnedURL(_ url: URL, in directory: URL) throws {
        guard ContextResolver.isContained(url, in: directory) else {
            throw ContextStoreError.invalidTarget
        }
    }

    private func validateStoreDirectory(_ kind: StoreKind) throws {
        switch kind {
        case .project:
            guard ContextResolver.isContained(projectContextDirectory, in: configuration.projectURL) else {
                throw ContextStoreError.invalidTarget
            }
        case .global:
            let parent = configuration.globalStoreURL.deletingLastPathComponent()
            guard ContextResolver.isContained(configuration.globalStoreURL, in: parent) else {
                throw ContextStoreError.invalidTarget
            }
        }
    }

    private func liveData(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ContextStoreError.missingRule }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= configuration.scan.maximumRuleBytes
        else {
            throw ContextStoreError.invalidEncoding
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= configuration.scan.maximumRuleBytes else { throw ContextStoreError.invalidEncoding }
        return data
    }

    private func liveString(at url: URL) throws -> String {
        let data = try liveData(at: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ContextStoreError.invalidEncoding
        }
        return content
    }

    private func externalActivationKey(for rule: ContextRule) throws -> String {
        guard rule.origin == .external,
              let url = rule.url,
              ContextResolver.isContained(url, in: configuration.projectURL)
        else {
            throw ContextStoreError.readOnlyExternal
        }
        let relative = lexicalRelativePath(for: url)
        return rule.provider.rawValue + ":" + relative
    }

    private func lexicalRelativePath(for url: URL) -> String {
        let rootPath = configuration.projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func removeRecord(id: UUID, from manifest: inout Manifest) {
        manifest.rules.removeAll { $0.id == id }
    }

    private func existingData(at url: URL, maximumBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw ContextStoreError.corruptManifest
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeRelative(_ target: String) -> String {
        var normalized = target
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private func catalogOrder(_ lhs: ContextRule, _ rhs: ContextRule) -> Bool {
        if lhs.origin != rhs.origin { return lhs.origin == .fsCode }
        if lhs.provider.stableOrder != rhs.provider.stableOrder {
            return lhs.provider.stableOrder < rhs.provider.stableOrder
        }
        let leftPath = lhs.url?.path ?? lhs.target ?? ""
        let rightPath = rhs.url?.path ?? rhs.target ?? ""
        if leftPath != rightPath { return leftPath < rightPath }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func recordOrder(_ lhs: RuleRecord, _ rhs: RuleRecord) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func stableUnique(_ diagnostics: [ContextDiagnostic]) -> [ContextDiagnostic] {
        var seen = Set<ContextDiagnostic>()
        return diagnostics.filter { seen.insert($0).inserted }
    }
}
