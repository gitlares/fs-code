import CryptoKit
import Foundation

struct ContextRuleBudget {
    private let maximumBytes: Int
    private let maximumCount: Int
    private(set) var usedBytes: Int
    private(set) var usedCount: Int

    init(configuration: ContextScanConfiguration, usedBytes: Int = 0, usedCount: Int = 0) {
        self.maximumBytes = configuration.maximumTotalRuleBytes
        self.maximumCount = configuration.maximumRuleCount
        self.usedBytes = usedBytes
        self.usedCount = usedCount
    }

    mutating func reserve(byteCount: Int, source: String, diagnostics: inout [ContextDiagnostic]) -> Bool {
        guard usedCount < maximumCount else {
            diagnostics.append(.init(.incompleteScan, "Context scan stopped after \(maximumCount) instruction sources; results are incomplete."))
            return false
        }
        guard byteCount <= maximumBytes - usedBytes else {
            diagnostics.append(.init(.incompleteScan, "Context scan stopped before \(source); the \(maximumBytes)-byte aggregate context catalog limit would be exceeded."))
            return false
        }
        usedCount += 1
        usedBytes += byteCount
        return true
    }
}

struct ContextExternalScanner {
    private enum Kind { case codex, claudeFile, claudeRule, cursorLegacy, cursorRule, copilotRepository, copilotRule, generic }
    private struct Candidate {
        let url: URL
        let relative: String
        let provider: ContextProvider
        let kind: Kind
    }
    private struct FrontMatter {
        let values: [String: [String]]
        let valid: Bool
    }

    let projectURL: URL
    let configuration: ContextScanConfiguration
    let activations: [String: Bool]
    let excludedDirectories: [URL]
    let initialBudget: ContextRuleBudget

    init(
        projectURL: URL,
        configuration: ContextScanConfiguration,
        activations: [String: Bool],
        excludedDirectories: [URL] = [],
        initialBudget: ContextRuleBudget? = nil
    ) {
        self.projectURL = projectURL
        self.configuration = configuration
        self.activations = activations
        self.excludedDirectories = excludedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.initialBudget = initialBudget ?? ContextRuleBudget(configuration: configuration)
    }

    func scan() -> ContextCatalogSnapshot {
        let canonicalRoot = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        var diagnostics: [ContextDiagnostic] = []
        inspectUnsupportedCodexSettings(canonicalRoot, diagnostics: &diagnostics)
        var candidates: [Candidate] = []
        var visitedDirectories = Set<String>()
        var visitedFiles = 0
        var stopped = false
        walk(
            projectURL.standardizedFileURL, relativeDirectory: "", depth: 0, canonicalRoot: canonicalRoot,
            visitedDirectories: &visitedDirectories, visitedFiles: &visitedFiles, stopped: &stopped,
            candidates: &candidates, diagnostics: &diagnostics
        )
        var budget = initialBudget
        var rules: [ContextRule] = []
        for candidate in candidates.sorted(by: { $0.relative < $1.relative }) {
            let byteCount = candidateByteCountIfSafelyKnown(candidate.url)
            guard budget.reserve(byteCount: byteCount, source: candidate.relative, diagnostics: &diagnostics) else {
                break
            }
            if let rule = read(candidate, canonicalRoot: canonicalRoot, diagnostics: &diagnostics) {
                rules.append(rule)
            }
        }
        applyCodexSelection(&rules)
        rules.sort {
            if $0.provider.stableOrder != $1.provider.stableOrder {
                return $0.provider.stableOrder < $1.provider.stableOrder
            }
            return ($0.url?.path ?? "") < ($1.url?.path ?? "")
        }
        return .init(rules: rules, diagnostics: unique(diagnostics))
    }

    private func candidateByteCountIfSafelyKnown(_ url: URL) -> Int {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= configuration.maximumRuleBytes
        else {
            return 0
        }
        return size
    }

    private func walk(
        _ directory: URL,
        relativeDirectory: String,
        depth: Int,
        canonicalRoot: URL,
        visitedDirectories: inout Set<String>,
        visitedFiles: inout Int,
        stopped: inout Bool,
        candidates: inout [Candidate],
        diagnostics: inout [ContextDiagnostic]
    ) {
        guard !stopped else { return }
        guard depth <= configuration.maximumDepth else {
            diagnostics.append(.init(.incompleteScan, "Scan depth limit reached at \(relativeDirectory)."))
            return
        }
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        if depth > 0, excludedDirectories.contains(where: {
            resolvedDirectory.path == $0.path || resolvedDirectory.path.hasPrefix($0.path + "/")
        }) {
            return
        }
        guard ContextResolver.isContained(resolvedDirectory, in: canonicalRoot) else {
            diagnostics.append(.init(.pathEscape, "Skipped directory outside the project: \(directory.path)"))
            return
        }
        guard visitedDirectories.insert(resolvedDirectory.path).inserted else {
            diagnostics.append(.init(.incompleteScan, "Skipped a symlink cycle or duplicate directory target: \(directory.path)"))
            return
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            diagnostics.append(.init(.incompleteScan, "Could not enumerate \(directory.path): \(error.localizedDescription)"))
            return
        }
        for child in children {
            guard !stopped else { return }
            let relative = relativeDirectory.isEmpty ? child.lastPathComponent : relativeDirectory + "/" + child.lastPathComponent
            let resolved = child.resolvingSymlinksInPath().standardizedFileURL
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let resolvedDirectoryFlag = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if values?.isDirectory == true || resolvedDirectoryFlag {
                if skippedDirectory(relative) { continue }
                guard ContextResolver.isContained(resolved, in: canonicalRoot) else {
                    diagnostics.append(.init(.pathEscape, "Skipped directory symlink outside the project: \(child.path)"))
                    continue
                }
                walk(
                    child, relativeDirectory: relative, depth: depth + 1, canonicalRoot: canonicalRoot,
                    visitedDirectories: &visitedDirectories, visitedFiles: &visitedFiles, stopped: &stopped,
                    candidates: &candidates, diagnostics: &diagnostics
                )
                continue
            }
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            visitedFiles += 1
            guard visitedFiles <= configuration.maximumVisitedFiles else {
                diagnostics.append(.init(.incompleteScan, "Scan stopped after \(configuration.maximumVisitedFiles) files; results are incomplete."))
                stopped = true
                return
            }
            guard let candidate = recognize(child, relative: relative) else { continue }
            guard ContextResolver.isContained(resolved, in: canonicalRoot) else {
                diagnostics.append(.init(.pathEscape, "Skipped instruction symlink outside the project: \(child.path)"))
                continue
            }
            candidates.append(candidate)
        }
    }

    private func skippedDirectory(_ relative: String) -> Bool {
        let basename = relative.split(separator: "/").last.map(String.init) ?? ""
        if [".git", ".build", "node_modules", "dist", "vendor"].contains(basename) { return true }
        return relative == ".fs/context" || relative.hasPrefix(".fs/context/")
    }

    private func recognize(_ url: URL, relative: String) -> Candidate? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        if name == "AGENTS.md" || name == "AGENTS.override.md" {
            return .init(url: url, relative: relative, provider: .codex, kind: .codex)
        }
        if name == "CLAUDE.md" || name == "CLAUDE.local.md" {
            return .init(url: url, relative: relative, provider: .claude, kind: .claudeFile)
        }
        if name.hasSuffix(".md") && hasPair(parts, ".claude", "rules") {
            return .init(url: url, relative: relative, provider: .claude, kind: .claudeRule)
        }
        if relative == ".cursorrules" {
            return .init(url: url, relative: relative, provider: .cursor, kind: .cursorLegacy)
        }
        if name.hasSuffix(".mdc") && hasPair(parts, ".cursor", "rules") {
            return .init(url: url, relative: relative, provider: .cursor, kind: .cursorRule)
        }
        if relative == ".github/copilot-instructions.md" {
            return .init(url: url, relative: relative, provider: .copilot, kind: .copilotRepository)
        }
        if relative.hasPrefix(".github/instructions/") && name.hasSuffix(".instructions.md") {
            return .init(url: url, relative: relative, provider: .copilot, kind: .copilotRule)
        }
        if name == "GEMINI.md" {
            return .init(url: url, relative: relative, provider: .generic, kind: .generic)
        }
        return nil
    }

    private func read(
        _ candidate: Candidate,
        canonicalRoot: URL,
        diagnostics: inout [ContextDiagnostic]
    ) -> ContextRule? {
        let resolved = candidate.url.resolvingSymlinksInPath().standardizedFileURL
        guard ContextResolver.isContained(resolved, in: canonicalRoot) else { return nil }
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > configuration.maximumRuleBytes {
            let diagnostic = ContextDiagnostic(.oversize, "Instruction exceeds the \(configuration.maximumRuleBytes)-byte scan limit: \(candidate.relative)")
            diagnostics.append(diagnostic)
            return rule(candidate, content: "", hash: ContextResolver.hash(""), scope: .project, target: nil, patterns: [], ruleDiagnostics: [diagnostic], applicability: .unsupported, reason: diagnostic.message)
        }
        let data: Data
        do {
            data = try Data(contentsOf: resolved, options: .mappedIfSafe)
        } catch {
            diagnostics.append(.init(.incompleteScan, "Could not read \(candidate.relative): \(error.localizedDescription)"))
            return nil
        }
        guard data.count <= configuration.maximumRuleBytes else {
            let diagnostic = ContextDiagnostic(.oversize, "Instruction exceeds the \(configuration.maximumRuleBytes)-byte scan limit: \(candidate.relative)")
            diagnostics.append(diagnostic)
            return rule(candidate, content: "", hash: ContextResolver.hash(data), scope: .project, target: nil, patterns: [], ruleDiagnostics: [diagnostic], applicability: .unsupported, reason: diagnostic.message)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            let diagnostic = ContextDiagnostic(.unsupportedSyntax, "Instruction is not valid UTF-8: \(candidate.relative)")
            diagnostics.append(diagnostic)
            return rule(candidate, content: "", hash: ContextResolver.hash(data), scope: .project, target: nil, patterns: [], ruleDiagnostics: [diagnostic], applicability: .unsupported, reason: diagnostic.message)
        }

        let base = baseFolder(candidate)
        var scope: ContextScope = base.isEmpty ? .project : .folder
        var target: String? = base.isEmpty ? nil : base
        var patterns: [String] = []
        var ruleDiagnostics: [ContextDiagnostic] = []
        var applicability: ContextApplicability = .automatic
        var reason: String?
        let frontMatter = parseFrontMatter(content)

        switch candidate.kind {
        case .codex, .cursorLegacy:
            break
        case .claudeFile:
            if containsImport(content) {
                applicability = .unsupported
                reason = "Claude imports are not expanded by this offline version."
            }
        case .claudeRule:
            if !frontMatter.valid {
                applicability = .unsupported
                reason = "Claude rule frontmatter is outside the supported metadata subset."
            } else if let paths = frontMatter.values["paths"], !paths.isEmpty {
                patterns = scoped(paths, base: base)
                scope = .glob
                target = patterns.first
            }
            if containsImport(content) {
                applicability = .unsupported
                reason = "Claude imports are not expanded by this offline version."
            }
        case .cursorRule:
            if !frontMatter.valid {
                applicability = .unsupported
                reason = "Cursor rule frontmatter is invalid."
            } else if frontMatter.values["alwaysApply"]?.first?.lowercased() == "true" {
                break
            } else if let globs = frontMatter.values["globs"], !globs.isEmpty {
                patterns = scoped(globs, base: base)
                scope = .glob
                target = patterns.first
            } else if frontMatter.values["description"]?.first?.isEmpty == false {
                applicability = .unknown
                reason = "Cursor Agent Requested rules need a provider decision or explicit activation."
            } else {
                applicability = .manual
                reason = "Cursor Manual rules require explicit activation."
            }
        case .copilotRepository:
            if containsImport(content) {
                applicability = .unsupported
                reason = "Copilot imports are not expanded by this offline version."
            }
        case .copilotRule:
            if !frontMatter.valid {
                applicability = .unsupported
                reason = "Copilot instruction frontmatter is invalid."
            } else if frontMatter.values["excludeAgent"]?.isEmpty == false {
                applicability = .unsupported
                reason = "excludeAgent requires a harness surface and is disabled offline."
            } else if let applyTo = frontMatter.values["applyTo"], !applyTo.isEmpty {
                patterns = scoped(applyTo, base: "")
                scope = .glob
                target = patterns.first
            } else {
                applicability = .unsupported
                reason = "Copilot modular instructions require applyTo metadata."
            }
        case .generic:
            applicability = .unsupported
            reason = "This instruction filename is visible, but its provider semantics are not implemented."
        }
        for pattern in patterns {
            if let invalid = ContextResolver.validateGlob(pattern) {
                applicability = .unsupported
                reason = invalid.message
                ruleDiagnostics.append(invalid)
                break
            }
        }
        if applicability == .unsupported, let reason, ruleDiagnostics.isEmpty {
            ruleDiagnostics.append(.init(.unsupportedSyntax, reason))
        }
        diagnostics.append(contentsOf: ruleDiagnostics)
        return rule(candidate, content: content, hash: ContextResolver.hash(data), scope: scope, target: target, patterns: patterns, ruleDiagnostics: ruleDiagnostics, applicability: applicability, reason: reason)
    }

    private func rule(
        _ candidate: Candidate,
        content: String,
        hash: String,
        scope: ContextScope,
        target: String?,
        patterns: [String],
        ruleDiagnostics: [ContextDiagnostic],
        applicability: ContextApplicability,
        reason: String?
    ) -> ContextRule {
        let key = candidate.provider.rawValue + ":" + candidate.relative
        return .init(
            id: stableID(candidate.provider, candidate.relative),
            name: candidate.url.lastPathComponent,
            url: candidate.url.standardizedFileURL,
            origin: .external,
            provider: candidate.provider,
            scope: scope,
            target: target,
            matchPatterns: patterns,
            enabled: activations[key] == true,
            content: content,
            hash: hash,
            diagnostics: ruleDiagnostics,
            applicability: applicability,
            applicabilityReason: reason
        )
    }

    private func applyCodexSelection(_ rules: inout [ContextRule]) {
        let indexes = rules.indices.filter { rules[$0].provider == .codex }
        let groups = Dictionary(grouping: indexes) { rules[$0].url?.deletingLastPathComponent().path ?? "" }
        for group in groups.values {
            let ordered = group.sorted { preference(rules[$0].name) < preference(rules[$1].name) }
            let selected = ordered.first { !rules[$0].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for index in ordered where index != selected {
                rules[index].applicability = .replaced
                rules[index].applicabilityReason = selected.map { "Replaced in the same directory by \(rules[$0].name)." }
                    ?? "Codex skips empty instruction files."
            }
        }
    }

    private func preference(_ name: String) -> Int {
        name == "AGENTS.override.md" ? 0 : 1
    }

    private func baseFolder(_ candidate: Candidate) -> String {
        var parts = candidate.relative.split(separator: "/").map(String.init)
        parts.removeLast()
        switch candidate.kind {
        case .claudeRule:
            if let marker = parts.lastIndex(of: ".claude") { parts = Array(parts[..<marker]) }
        case .claudeFile:
            if parts.last == ".claude" { parts.removeLast() }
        case .cursorRule:
            if let marker = parts.lastIndex(of: ".cursor") { parts = Array(parts[..<marker]) }
        case .copilotRepository, .copilotRule:
            parts = []
        case .codex, .cursorLegacy, .generic:
            break
        }
        return parts.joined(separator: "/")
    }

    private func scoped(_ values: [String], base: String) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            var pattern = unquote($0).trimmingCharacters(in: .whitespacesAndNewlines)
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            guard !pattern.isEmpty else { return nil }
            if !base.isEmpty && pattern != base && !pattern.hasPrefix(base + "/") { pattern = base + "/" + pattern }
            return seen.insert(pattern).inserted ? pattern : nil
        }
    }

    private func parseFrontMatter(_ content: String) -> FrontMatter {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return .init(values: [:], valid: true) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return .init(values: [:], valid: false)
        }
        var result: [String: [String]] = [:]
        var current: String?
        for line in lines[1..<end] {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") { continue }
            if value.hasPrefix("-"), let current {
                guard ["paths", "globs", "applyTo"].contains(current) else {
                    return .init(values: result, valid: false)
                }
                let item = stripComment(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))
                guard !item.isEmpty, !isUnsupportedComplexValue(item, allowList: false) else {
                    return .init(values: result, valid: false)
                }
                result[current, default: []].append(unquote(item))
                continue
            }
            guard let colon = value.firstIndex(of: ":") else { return .init(values: result, valid: false) }
            let key = String(value[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else { return .init(values: result, valid: false) }
            current = key
            let raw = stripComment(String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            if raw == "|" || raw == ">" || raw.hasPrefix("|") || raw.hasPrefix(">") {
                return .init(values: result, valid: false)
            }
            if key == "alwaysApply", !raw.isEmpty {
                let bool = unquote(raw).lowercased()
                guard bool == "true" || bool == "false" else { return .init(values: result, valid: false) }
            }
            if ["paths", "globs", "applyTo"].contains(key) {
                if raw.hasPrefix("[") && raw.hasSuffix("]") {
                    let list = String(raw.dropFirst().dropLast())
                    result[key] = splitCommaSeparated(list)
                } else {
                    guard !isUnsupportedComplexValue(raw, allowList: false) else {
                        return .init(values: result, valid: false)
                    }
                    result[key] = isQuoted(raw) ? [unquote(raw)].filter { !$0.isEmpty } : splitCommaSeparated(raw)
                }
            } else {
                guard !isUnsupportedComplexValue(raw, allowList: false) else {
                    return .init(values: result, valid: false)
                }
                result[key] = raw.isEmpty ? [] : [unquote(raw)]
            }
        }
        return .init(values: result, valid: true)
    }

    private func containsImport(_ content: String) -> Bool {
        var fenced = false
        let fence = String(repeating: "\u{60}", count: 3)
        for raw in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(fence) || line.hasPrefix("~~~") { fenced.toggle() }
            else if !fenced && lineContainsImportOutsideInlineCode(String(raw)) { return true }
        }
        return false
    }

    private func inspectUnsupportedCodexSettings(_ root: URL, diagnostics: inout [ContextDiagnostic]) {
        let url = root.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard ContextResolver.isContained(resolved, in: root) else {
            diagnostics.append(.init(.pathEscape, "Skipped .codex/config.toml symlink outside the project: \(url.path)"))
            return
        }
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= configuration.maximumRuleBytes,
              let data = try? Data(contentsOf: resolved, options: [.mappedIfSafe]),
              data.count <= configuration.maximumRuleBytes,
              let text = String(data: data, encoding: .utf8)
        else {
            diagnostics.append(.init(.incompleteScan, "Could not safely inspect .codex/config.toml context settings."))
            return
        }
        if text.contains("project_doc_fallback_filenames") || text.contains("project_doc_max_bytes") {
            diagnostics.append(.init(.incompleteScan, "Custom Codex project document settings in .codex/config.toml are not interpreted by this version."))
        }
    }

    private func unquote(_ value: String) -> String {
        if value.count >= 2 && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func isQuoted(_ value: String) -> Bool {
        value.count >= 2 && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")))
    }

    private func splitCommaSeparated(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                current.append(character)
            } else if character == ",", quote == nil {
                let item = unquote(current.trimmingCharacters(in: .whitespacesAndNewlines))
                if !item.isEmpty { items.append(item) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let item = unquote(current.trimmingCharacters(in: .whitespacesAndNewlines))
        if !item.isEmpty { items.append(item) }
        return items
    }

    private func stripComment(_ value: String) -> String {
        var result = ""
        var quote: Character?
        var previous: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            }
            if character == "#", quote == nil, (previous == nil || previous == " " || previous == "\t") {
                break
            }
            result.append(character)
            previous = character
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func isUnsupportedComplexValue(_ value: String, allowList: Bool) -> Bool {
        guard !value.isEmpty, !isQuoted(value) else { return false }
        if value.hasPrefix("{") || value.hasSuffix("}") { return true }
        if !allowList, (value.hasPrefix("[") || value.hasSuffix("]")) { return true }
        return false
    }

    private func lineContainsImportOutsideInlineCode(_ line: String) -> Bool {
        var inInlineCode = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "`" {
                inInlineCode.toggle()
            } else if character == "@", !inInlineCode {
                let next = line.index(after: index)
                if next < line.endIndex,
                   isImportCharacter(line[next]),
                   previous == nil || previous?.isWhitespace == true
                {
                    return true
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return false
    }

    private func isImportCharacter(_ character: Character) -> Bool {
        character == "/" || character == "." || character == "~" || character == "_" || character == "-" ||
            character.isLetter || character.isNumber
    }

    private func hasPair(_ parts: [String], _ first: String, _ second: String) -> Bool {
        guard parts.count >= 3 else { return false }
        return (0..<(parts.count - 1)).contains { parts[$0] == first && parts[$0 + 1] == second }
    }

    private func stableID(_ provider: ContextProvider, _ relative: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((provider.rawValue + "\u{0}" + relative).utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func unique(_ values: [ContextDiagnostic]) -> [ContextDiagnostic] {
        var seen = Set<ContextDiagnostic>()
        return values.filter { seen.insert($0).inserted }
    }
}
