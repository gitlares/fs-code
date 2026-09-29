import AgentContextCore
import Darwin
import Foundation

actor NativeProjectTools {
    let rootURL: URL
    private let commandRunner: ProjectCommandRunner
    private let contextStore: ContextStore
    private static let memoryRuleName = "Memory (agent-authored)"
    private static let memoryMaxBytes = 4_000

    init(rootURL: URL, commandRunner: ProjectCommandRunner) {
        self.rootURL = rootURL
        self.commandRunner = commandRunner
        self.contextStore = ContextStore(configuration: ContextStoreConfiguration(projectURL: rootURL))
    }
    func execute(name: String, arguments: [String: String], mode: AgentMode = .ask, selectedPlanID: String? = nil) async -> String {
        switch name {
        case "read_project_file":
            guard let path = arguments["relative_path"], let url = projectFile(path) else { return "Path is outside the project." }
            guard let text = readText(url) else { return "File is unavailable or not UTF-8 text." }
            return String(text.prefix(200_000))
        case "list_project_files":
            return projectFiles().joined(separator: "\n")
        case "read_memory":
            return await readMemory()
        case "write_memory":
            return await writeMemory(
                action: (arguments["action"] ?? "").lowercased(),
                entry: arguments["entry"],
                match: arguments["match"]
            )
        case "search_project_text":
            guard let query = arguments["query"], !query.isEmpty, query.utf8.count <= 512 else { return "Search query was invalid." }
            if let ripgrepResult = await searchWithRipgrep(query: query) { return ripgrepResult }
            return searchLinearly(query: query)
        case "search_code_pattern":
            guard let pattern = arguments["pattern"], !pattern.isEmpty, pattern.utf8.count <= 512 else { return "Pattern was invalid." }
            return await searchWithAstGrep(pattern: pattern, language: arguments["language"])
        case "fs_write_plan":
            guard mode == .plan,
                  let path = arguments["relative_path"],
                  let content = arguments["content"],
                  isDraftPlanPath(path),
                  content.utf8.count <= 900_000,
                  isDraftPlan(content),
                  planPathIsSafe(path),
                  let url = projectFile(path) else {
                return "Only draft Markdown plans under .fs/plans may be written in Plan mode."
            }
            do {
                let planID = url.deletingPathExtension().lastPathComponent
                _ = try ProjectPlanStore(projectURL: rootURL).importDraft(planID: planID, markdown: content)
                return "Saved draft plan: \(path)"
            } catch { return "The draft plan could not be saved." }
        case "fs_update_plan":
            guard mode == .build,
                  let selectedPlanID, arguments["plan_id"] == selectedPlanID,
                  let revisionText = arguments["expected_revision"], let revision = Int(revisionText),
                  let markdown = arguments["markdown"] else { return "Only the host-selected approved plan may be updated in Build mode." }
            do {
                _ = try ProjectPlanStore(projectURL: rootURL).updateExecution(planID: selectedPlanID, expectedRevision: revision) { $0 = markdown }
                return "Updated execution status for .fs/plans/\(selectedPlanID).md"
            } catch { return "The plan execution update was rejected." }
        default:
            return "Tool unavailable in this project."
        }
    }

    /// Best-effort: `rg` gives real regex/gitignore-aware search over the whole tree, not just the
    /// first 500 files. Falls back to the linear scan when `rg` is missing or errors.
    private func searchWithRipgrep(query: String) async -> String? {
        let arguments = ["rg", "-i", "-F", "--line-number", "--no-heading", "--color=never", "--max-columns=500", "--", query, "."]
        guard let result = try? await commandRunner.run(arguments: arguments, timeout: 10, maxOutputBytes: 65_536) else { return nil }
        switch result.exitCode {
        case 0:
            let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).prefix(100)
            return lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
        case 1:
            return "No matches."
        default:
            return nil
        }
    }

    /// ast-grep gives structural (AST-aware) matching. Unlike `rg`, a missing binary has no safe
    /// textual fallback — pattern syntax is not valid regex — so we return an explicit message
    /// instead of silently degrading to search_project_text.
    private func searchWithAstGrep(pattern: String, language: String?) async -> String {
        var arguments = ["ast-grep", "run", "--pattern", pattern, "--color=never", "--json=compact"]
        if let language, !language.isEmpty { arguments += ["--lang", language] }
        arguments.append(".")
        guard let result = try? await commandRunner.run(arguments: arguments, timeout: 10, maxOutputBytes: 65_536) else {
            return "ast-grep is not installed or could not run. Install it (e.g. `brew install ast-grep`) or use search_project_text for a plain-text search."
        }
        guard result.exitCode == 0 else {
            return result.output.isEmpty ? "No matches." : "ast-grep reported an error:\n\(result.output.prefix(2_000))"
        }
        return Self.formatAstGrepMatches(result.output)
    }

    private static func formatAstGrepMatches(_ jsonOutput: String) -> String {
        guard let data = jsonOutput.data(using: .utf8),
              let matches = try? JSONDecoder().decode([AstGrepMatch].self, from: data), !matches.isEmpty else {
            return "No matches."
        }
        let lines = matches.prefix(100).map { match -> String in
            let snippet = match.lines.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? match.lines
            return "\(match.file):\(match.range.start.line + 1): \(snippet.prefix(300))"
        }
        return lines.joined(separator: "\n")
    }

    private struct AstGrepMatch: Decodable {
        let file: String
        let lines: String
        let range: Range
        struct Range: Decodable { let start: Position }
        struct Position: Decodable { let line: Int }
    }

    private func searchLinearly(query: String) -> String {
        var matches: [String] = []
        for path in projectFiles() {
            if Task.isCancelled { return "Cancelled." }
            guard matches.count < 100, let url = projectFile(path),
                  let text = readText(url) else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where String(line).localizedCaseInsensitiveContains(query) {
                matches.append("\(path):\(offset + 1): \(line.prefix(500))")
                if matches.count == 100 { break }
            }
        }
        return matches.isEmpty ? "No matches." : matches.joined(separator: "\n")
    }

    private func isDraftPlanPath(_ path: String) -> Bool {
        path.hasPrefix(".fs/plans/") && path.hasSuffix(".md") &&
            !path.dropFirst(".fs/plans/".count).contains("/")
    }

    private func isDraftPlan(_ content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return false }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return false }
            let key = String(pieces[0])
            guard fields[key] == nil else { return false }
            fields[key] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }
        return fields["status"] == "draft" && fields["approved_via"] == "none"
    }

    private func planPathIsSafe(_ path: String) -> Bool {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var current = root
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var status = stat()
            if lstat(current.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }

    private func projectFile(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    private func projectFiles() -> [String] {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [String] = []
        var visited = 0
        while !Task.isCancelled, visited < 5_000, files.count < 500, let url = enumerator.nextObject() as? URL {
            visited += 1
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            files.append(resolved.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        return files.sorted()
    }


    // MARK: - Project memory
    //
    // Backed by `ContextStore` so the same rule the agent writes here is the one
    // already pushed into every request's system context (no separate injection
    // path to build or keep in sync) and already visible/editable in the Agent
    // Context sidebar (no separate UI to build). It lives at project scope, not
    // per connection profile, so switching accounts/models does not silo it.

    private func findMemoryRule() async -> ContextRule? {
        guard let snapshot = try? await contextStore.load() else { return nil }
        return snapshot.rules.first { $0.origin == .fsCode && $0.scope == .project && $0.name == Self.memoryRuleName }
    }

    private func readMemory() async -> String {
        guard let rule = await findMemoryRule(), !rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Memory is empty. Use write_memory (action: \"add\", entry: \"...\") to save something worth " +
                "keeping for next time: a correction, a pattern confirmed by seeing it in 2+ places (not a single " +
                "occurrence), or a non-obvious decision. Skip anything cheaper to re-derive by reading the code."
        }
        var annotatedLines: [String] = []
        for line in rule.content.split(separator: "\n", omittingEmptySubsequences: false) {
            annotatedLines.append(await annotateIfStale(String(line)))
        }
        let byteCount = rule.content.utf8.count
        return "\(annotatedLines.joined(separator: "\n"))\n\n(\(byteCount)/\(Self.memoryMaxBytes) bytes used)"
    }

    private func writeMemory(action: String, entry: String?, match: String?) async -> String {
        if let entry, Self.containsLikelySecret(entry) {
            return "Refused: this looks like it contains a secret, API key, token, or credential. Memory is a " +
                "plaintext file — never store the value itself. Reference where it lives instead " +
                "(e.g. \"the OpenAI key from .env.local\" or \"see the fs-code Keychain item\")."
        }
        let current = await findMemoryRule()
        var lines = (current?.content ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        switch action {
        case "add":
            guard let entry, !entry.isEmpty else { return "write_memory (add) requires a non-empty \"entry\"." }
            let bullet = "- \(entry)"
            guard !lines.contains(bullet) else { return "That's already recorded." }
            lines.append(bullet)
        case "replace":
            guard let match, !match.isEmpty, let entry, !entry.isEmpty else {
                return "write_memory (replace) requires both \"match\" and \"entry\"."
            }
            guard let index = lines.firstIndex(where: { $0.contains(match) }) else {
                return "No memory entry contains \"\(match)\"."
            }
            lines[index] = "- \(entry)"
        case "remove":
            guard let match, !match.isEmpty else { return "write_memory (remove) requires \"match\"." }
            let before = lines.count
            lines.removeAll { $0.contains(match) }
            guard lines.count < before else { return "No memory entry contains \"\(match)\"." }
        default:
            return "Unknown action \"\(action)\". Use \"add\", \"replace\", or \"remove\"."
        }

        let newContent = lines.joined(separator: "\n")
        guard newContent.utf8.count <= Self.memoryMaxBytes else {
            let listing = lines.map { "  \($0)" }.joined(separator: "\n")
            return "Memory is full (would be \(newContent.utf8.count)/\(Self.memoryMaxBytes) bytes). Merge or " +
                "remove an existing entry first, then retry:\n\(listing)"
        }
        do {
            if let current {
                _ = try await contextStore.update(id: current.id, expectedHash: current.hash, content: newContent)
            } else {
                _ = try await contextStore.create(name: Self.memoryRuleName, scope: .project, content: newContent)
            }
            return "Memory saved (\(newContent.utf8.count)/\(Self.memoryMaxBytes) bytes)."
        } catch {
            return "Memory was not saved: \(error.localizedDescription)"
        }
    }

    /// Flags backticked file paths and identifiers that no longer exist in the
    /// live project, so a stale memory entry gets caught automatically instead
    /// of silently misleading a future turn.
    private func annotateIfStale(_ line: String) async -> String {
        for span in backtickedSpans(in: line) {
            if span.contains("/") || span.contains(".") {
                if projectFile(span) == nil, !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(span).path) {
                    return line + "  ⚠️ stale: `\(span)` not found in the project"
                }
            } else if span.count > 2, span.first?.isLetter == true || span.first == "_" {
                if await !existsInProject(literal: span) {
                    return line + "  ⚠️ stale: `\(span)` not found in current code"
                }
            }
        }
        return line
    }

    /// A deterministic, non-LLM-dependent gate: `write_memory`'s content lands in
    /// a plaintext file, so refusing to store secrets can't rely on the model
    /// remembering not to — this always runs regardless of what was asked.
    private static let secretPrefixes = [
        "sk-", "sk-ant-", "AKIA", "ASIA", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "glpat-", "AIza", "ya29.", "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "-----BEGIN"
    ]
    private static let jwtShapedPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)
    private static let labeledSecretPattern = try? NSRegularExpression(
        pattern: #"(?i)(api[_-]?key|secret|token|password|credential)\w*[\s:="']{1,4}[A-Za-z0-9_\-/+=]{16,}"#
    )

    private static func containsLikelySecret(_ text: String) -> Bool {
        if secretPrefixes.contains(where: text.contains) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if jwtShapedPattern?.firstMatch(in: text, range: range) != nil { return true }
        if labeledSecretPattern?.firstMatch(in: text, range: range) != nil { return true }
        return false
    }

    private func backtickedSpans(in line: String) -> [String] {
        var spans: [String] = []
        var current: String?
        for character in line {
            if character == "`" {
                if let value = current { spans.append(value) }
                current = current == nil ? "" : nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return spans.filter { !$0.isEmpty }
    }

    private func existsInProject(literal: String) async -> Bool {
        guard literal.utf8.count <= 200 else { return true }
        let arguments = ["rg", "-l", "-F", "--max-count=1", "--", literal, "."]
        guard let result = try? await commandRunner.run(arguments: arguments, timeout: 5, maxOutputBytes: 4_096) else {
            return true // rg unavailable or errored: never flag stale on a tooling failure
        }
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default: return true
        }
    }

    private func readText(_ url: URL) -> String? {
        guard !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
