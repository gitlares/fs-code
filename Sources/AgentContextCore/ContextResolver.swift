import CryptoKit
import Foundation

public struct ContextResolverConfiguration: Sendable {
    public var maximumUTF8Bytes: Int

    public init(maximumUTF8Bytes: Int = 64 * 1024) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }
}

public struct ContextResolver: Sendable {
    public let configuration: ContextResolverConfiguration

    public init(configuration: ContextResolverConfiguration = .init()) {
        self.configuration = configuration
    }

    public func resolve(snapshot: ContextCatalogSnapshot, projectURL: URL, paths: [URL]) -> ContextResolution {
        resolve(
            rules: snapshot.rules,
            projectURL: projectURL,
            paths: paths,
            catalogDiagnostics: snapshot.diagnostics
        )
    }

    public func resolve(rules: [ContextRule], projectURL: URL, paths: [URL]) -> ContextResolution {
        resolve(rules: rules, projectURL: projectURL, paths: paths, catalogDiagnostics: [])
    }

    private func resolve(
        rules: [ContextRule],
        projectURL: URL,
        paths: [URL],
        catalogDiagnostics: [ContextDiagnostic]
    ) -> ContextResolution {
        let project = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        var diagnostics = catalogDiagnostics
        var requestedPaths: [RequestedPath] = []
        var seenPaths = Set<String>()

        for requestedURL in paths {
            let requested = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isContained(requested, in: project) else {
                diagnostics.append(.init(.pathEscape, "Requested path is outside the project: \(requested.path)"))
                continue
            }
            let relative = Self.relativePath(for: requested, in: project)
            if seenPaths.insert(requested.path).inserted {
                requestedPaths.append(.init(absolute: requested.path, relative: relative))
            }
        }

        let duplicateIDs = Dictionary(grouping: rules, by: \.id).filter { $0.value.count > 1 }.keys
        var candidates: [Candidate] = []
        for rule in rules {
            var effectiveRule = rule
            var validationDiagnostics = validate(rule: rule, project: project)
            if duplicateIDs.contains(rule.id) {
                validationDiagnostics.append(.init(.conflict, "Duplicate context identifier: \(rule.id.uuidString)"))
            }
            effectiveRule.diagnostics.append(contentsOf: validationDiagnostics)
            diagnostics.append(contentsOf: effectiveRule.diagnostics)
            let matches = matchedPaths(for: effectiveRule, requestedPaths: requestedPaths, hasExplicitPaths: !paths.isEmpty)
            let hasStructuralFailure = !validationDiagnostics.isEmpty
            let shouldPresent = !matches.isEmpty || (paths.isEmpty && isProjectLevelOwnedRule(effectiveRule)) || hasStructuralFailure
            guard shouldPresent else { continue }

            let stateAndReason = state(for: effectiveRule)
            candidates.append(
                Candidate(
                    rule: effectiveRule,
                    state: stateAndReason.0,
                    reason: stateAndReason.1,
                    matchedPaths: matches
                )
            )
        }

        candidates.sort { lhs, rhs in
            let left = precedence(lhs.rule)
            let right = precedence(rhs.rule)
            if left != right { return left < right }
            return lhs.rule.id.uuidString < rhs.rule.id.uuidString
        }

        var consolidatedBlocks: [String] = []
        var seenContent: [Data: UUID] = [:]
        var entries: [ContextResolutionEntry] = []
        var activeOrder = 0

        for candidate in candidates {
            guard candidate.state == .active else {
                entries.append(
                    .init(
                        rule: candidate.rule,
                        state: candidate.state,
                        reason: candidate.reason,
                        order: nil,
                        matchedPaths: candidate.matchedPaths
                    )
                )
                continue
            }

            let exactContent = Data(candidate.rule.content.utf8)
            if let originalID = seenContent[exactContent] {
                let diagnostic = ContextDiagnostic(
                    .duplicate,
                    "Exact duplicate content in \(candidate.rule.name); first source is \(originalID.uuidString)."
                )
                diagnostics.append(diagnostic)
                entries.append(
                    .init(
                        rule: candidate.rule,
                        state: .replaced,
                        reason: "Exact duplicate of \(originalID.uuidString)",
                        order: nil,
                        matchedPaths: candidate.matchedPaths
                    )
                )
                continue
            }

            seenContent[exactContent] = candidate.rule.id
            activeOrder += 1
            entries.append(
                .init(
                    rule: candidate.rule,
                    state: .active,
                    reason: candidate.reason,
                    order: activeOrder,
                    matchedPaths: candidate.matchedPaths
                )
            )
            consolidatedBlocks.append(block(for: candidate.rule))
        }

        let consolidatedText = consolidatedBlocks.joined(separator: "\n")
        let byteCount = consolidatedText.lengthOfBytes(using: .utf8)
        if byteCount > configuration.maximumUTF8Bytes {
            diagnostics.append(
                .init(
                    .oversize,
                    "Effective context is \(byteCount) UTF-8 bytes; the configured limit is \(configuration.maximumUTF8Bytes)."
                )
            )
        }

        diagnostics = stableUnique(diagnostics)
        let structurallyIncomplete = diagnostics.contains {
            switch $0.kind {
            case .incompleteScan, .pathEscape, .invalidManifest, .conflict, .missing:
                true
            default:
                false
            }
        }

        return .init(
            entries: entries,
            consolidatedText: consolidatedText,
            utf8ByteCount: byteCount,
            approximateTokenCount: (byteCount + 3) / 4,
            diagnostics: diagnostics,
            canSend: byteCount <= configuration.maximumUTF8Bytes && !structurallyIncomplete
        )
    }

    public static func hash(_ content: String) -> String {
        hash(Data(content.utf8))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Validates the deliberately small glob subset used by FS Code.
    public static func validateGlob(_ pattern: String) -> ContextDiagnostic? {
        let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            return .init(.unsupportedPattern, "Glob must be a non-empty project-relative pattern without '..'.")
        }
        if pattern.contains("\\") || pattern.contains("[") || pattern.contains("]") ||
            pattern.contains("{") || pattern.contains("}") || pattern.contains("!")
        {
            return .init(.unsupportedPattern, "Only '*', '**', and '?' glob operators are supported.")
        }
        return nil
    }

    public static func globMatches(_ pattern: String, path: String) -> Bool {
        guard validateGlob(pattern) == nil else { return false }
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterDouble = pattern.index(after: next)
                    if afterDouble < pattern.endIndex, pattern[afterDouble] == "/" {
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterDouble)
                    } else {
                        expression += ".*"
                        index = afterDouble
                    }
                } else {
                    expression += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                expression += "[^/]"
                index = pattern.index(after: index)
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index = pattern.index(after: index)
            }
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func relativePath(for candidate: URL, in root: URL) -> String {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidatePath != rootPath else { return "" }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    private func matchedPaths(for rule: ContextRule, requestedPaths: [RequestedPath], hasExplicitPaths: Bool) -> [String] {
        if !hasExplicitPaths {
            return isProjectLevelOwnedRule(rule) ? [] : []
        }
        return requestedPaths.filter { matches(rule, relativePath: $0.relative) }.map(\.absolute)
    }

    private func isProjectLevelOwnedRule(_ rule: ContextRule) -> Bool {
        rule.origin == .fsCode && (rule.scope == .global || rule.scope == .project)
    }

    private func matches(_ rule: ContextRule, relativePath: String) -> Bool {
        switch rule.scope {
        case .global, .project:
            return true
        case .folder:
            guard let target = rule.target else { return false }
            let folder = Self.normalizeRelative(target)
            return folder.isEmpty || relativePath == folder || relativePath.hasPrefix(folder + "/")
        case .file:
            guard let target = rule.target else { return false }
            return relativePath == Self.normalizeRelative(target)
        case .glob:
            let patterns = rule.matchPatterns.isEmpty ? rule.target.map { [$0] } ?? [] : rule.matchPatterns
            return patterns.contains { Self.globMatches($0, path: relativePath) }
        case .external:
            guard let target = rule.target else { return true }
            let normalized = Self.normalizeRelative(target)
            return relativePath == normalized || relativePath.hasPrefix(normalized + "/")
        }
    }

    private func state(for rule: ContextRule) -> (ContextState, String) {
        if rule.diagnostics.contains(where: { $0.kind == .conflict }) {
            return (.conflict, "Conflicting source identity")
        }
        if rule.diagnostics.contains(where: {
            [.missing, .invalidManifest, .invalidMetadata, .unsupportedPattern, .unsupportedSyntax, .pathEscape].contains($0.kind)
        }) {
            return (.unsupported, rule.diagnostics.first?.message ?? "Invalid context metadata")
        }
        switch rule.applicability {
        case .unsupported:
            return (.unsupported, rule.applicabilityReason ?? "Unsupported provider syntax")
        case .replaced:
            return (.replaced, rule.applicabilityReason ?? "Replaced by provider precedence")
        case .manual where !rule.enabled:
            return (.manual, rule.applicabilityReason ?? "Requires explicit activation")
        case .unknown where !rule.enabled:
            return (.unknown, rule.applicabilityReason ?? "Provider decides applicability dynamically")
        case .automatic, .manual, .unknown:
            break
        }
        guard rule.enabled else {
            return (rule.origin == .external ? .inactive : .ignored, "Disabled")
        }
        return (.active, rule.origin == .external ? "Explicitly activated and matched" : "Enabled and matched")
    }

    private func precedence(_ rule: ContextRule) -> SortKey {
        if rule.origin == .external {
            let depth: Int
            switch rule.scope {
            case .folder:
                depth = Self.normalizeRelative(rule.target ?? "").split(separator: "/").count
            default:
                depth = 0
            }
            return SortKey(
                stage: 5,
                provider: rule.provider.stableOrder,
                depth: depth,
                priority: rule.priority,
                path: stableSourcePath(rule)
            )
        }

        let stage: Int
        let depth: Int
        switch rule.scope {
        case .global:
            stage = 0
            depth = 0
        case .project:
            stage = 1
            depth = 0
        case .folder:
            stage = 2
            depth = Self.normalizeRelative(rule.target ?? "").split(separator: "/").count
        case .glob:
            stage = 3
            depth = 0
        case .file:
            stage = 4
            depth = 0
        case .external:
            stage = 5
            depth = 0
        }
        return SortKey(stage: stage, provider: 0, depth: depth, priority: rule.priority, path: stableSourcePath(rule))
    }

    private func stableSourcePath(_ rule: ContextRule) -> String {
        rule.url?.standardizedFileURL.path ?? rule.target ?? ""
    }

    private func block(for rule: ContextRule) -> String {
        let source = rule.url?.standardizedFileURL.path ?? rule.target ?? "global"
        let safeName = quoted(rule.name)
        let safeSource = quoted(source)
        let header = "--- Agent Context: \(safeName) [\(rule.provider.rawValue)] source=\(safeSource) id=\(rule.id.uuidString) hash=\(rule.hash) ---"
        return header + "\n" + rule.content
    }

    private func validate(rule: ContextRule, project: URL) -> [ContextDiagnostic] {
        var diagnostics: [ContextDiagnostic] = []
        if rule.origin == .fsCode && rule.provider != .fsCode {
            diagnostics.append(.init(.invalidMetadata, "Owned context must use the FS Code provider."))
        }
        if rule.origin == .external, let url = rule.url, !Self.isContained(url, in: project) {
            diagnostics.append(.init(.pathEscape, "External context source escapes the project: \(url.path)"))
        }
        switch rule.scope {
        case .global:
            if rule.origin != .fsCode || rule.target != nil {
                diagnostics.append(.init(.invalidMetadata, "Global scope is reserved for owned rules and has no target."))
            }
        case .project:
            if rule.target != nil {
                diagnostics.append(.init(.invalidMetadata, "Project scope has no target."))
            }
        case .folder, .file:
            guard let target = rule.target, validRelativePath(target) else {
                diagnostics.append(.init(.pathEscape, "Folder and file scopes require a contained project-relative target."))
                break
            }
            let candidate = project.appendingPathComponent(target)
            if !Self.isContained(candidate, in: project) {
                diagnostics.append(.init(.pathEscape, "Context target escapes the project: \(target)"))
            }
        case .glob:
            let patterns = rule.matchPatterns.isEmpty ? rule.target.map { [$0] } ?? [] : rule.matchPatterns
            if patterns.isEmpty {
                diagnostics.append(.init(.unsupportedPattern, "Glob scope requires at least one pattern."))
            } else {
                diagnostics.append(contentsOf: patterns.compactMap(Self.validateGlob))
            }
        case .external:
            diagnostics.append(.init(.invalidMetadata, "External origin must expose its native project, folder, glob, or file scope."))
        }
        return diagnostics
    }

    private func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty &&
            !path.hasPrefix("/") &&
            !path.contains("\\") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func stableUnique(_ values: [ContextDiagnostic]) -> [ContextDiagnostic] {
        var seen = Set<ContextDiagnostic>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizeRelative(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

private struct Candidate {
    let rule: ContextRule
    let state: ContextState
    let reason: String
    let matchedPaths: [String]
}

private struct RequestedPath {
    let absolute: String
    let relative: String
}

private struct SortKey: Comparable {
    let stage: Int
    let provider: Int
    let depth: Int
    let priority: Int
    let path: String

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
        if lhs.stage != rhs.stage { return lhs.stage < rhs.stage }
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.path < rhs.path
    }
}
