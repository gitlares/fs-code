import Foundation

/// Captures a best-effort before/after snapshot of the project tree around one
/// `run_development_command` invocation, then imports any resulting file changes into
/// `AgentFileChangeService`'s audited journal via `recordCommandWrite`. Scoped to a single
/// command's execution window — not a continuous watcher — so it does not run into the
/// concurrent-attribution ambiguity that `docs/AGENT_EXECUTION_PLAN.md:33` already rules out for a
/// continuous filesystem watcher.
enum CommandWriteAuditor {
    struct Snapshot {
        struct Entry { let text: String; let modificationDate: Date; let size: Int }
        let entriesByPath: [String: Entry]
    }

    struct ImportSummary {
        let auditedPaths: [String]
        let unauditedDeletions: [String]
        let budgetExceeded: Bool

        var suffixText: String {
            var parts: [String] = []
            if budgetExceeded {
                parts.append("(project exceeds the audit snapshot budget; writes were not audited)")
            } else if !auditedPaths.isEmpty {
                parts.append("(\(auditedPaths.count) file change\(auditedPaths.count == 1 ? "" : "s") audited)")
            }
            if !unauditedDeletions.isEmpty {
                parts.append("(\(unauditedDeletions.count) deletion\(unauditedDeletions.count == 1 ? "" : "s") could not be audited: \(unauditedDeletions.joined(separator: ", ")))")
            }
            return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        }
    }

    /// Matches AgentFileChangeService.maximumTextBytes: a file this service could never audit
    /// anyway is not worth including in the snapshot.
    private static let maximumFileBytes = AgentFileChangeService.maximumTextBytes
    private static let maximumTotalBytes = 64 * 1_048_576
    private static let excludedTopLevelNames: Set<String> = [".git", ".fscode", ".build", "node_modules", "DerivedData", ".swiftpm"]

    /// Returns nil if the tree exceeds the audit budget. Callers must not pretend coverage they
    /// don't have — run the command anyway (the capability was already explicitly granted) but
    /// mark its output as unaudited.
    static func snapshot(projectRoot: URL) -> Snapshot? {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var entries: [String: Snapshot.Entry] = [:]
        var totalBytes = 0
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(of: url, under: root)
            if isExcluded(relative) { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumFileBytes,
                  let modificationDate = values.contentModificationDate,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            totalBytes += size
            guard totalBytes <= maximumTotalBytes else { return nil }
            entries[relative] = Snapshot.Entry(text: text, modificationDate: modificationDate, size: size)
        }
        return Snapshot(entriesByPath: entries)
    }

    static func importChanges(
        before: Snapshot?,
        projectRoot: URL,
        changeService: AgentFileChangeService?,
        threadID: String,
        turnID: String
    ) async -> ImportSummary {
        guard let before else { return ImportSummary(auditedPaths: [], unauditedDeletions: [], budgetExceeded: true) }
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return ImportSummary(auditedPaths: [], unauditedDeletions: [], budgetExceeded: false) }

        var seenPaths: Set<String> = []
        var auditedPaths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(of: url, under: root)
            if isExcluded(relative) { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            seenPaths.insert(relative)
            guard let size = values.fileSize, size <= maximumFileBytes,
                  let modificationDate = values.contentModificationDate else { continue }
            let previous = before.entriesByPath[relative]
            if let previous, previous.size == size, previous.modificationDate == modificationDate { continue }
            guard let afterText = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let beforeText = previous?.text
            guard beforeText != afterText else { continue }
            guard let changeService,
                  let record = try? await changeService.recordCommandWrite(
                      relativePath: relative, beforeText: beforeText, afterText: afterText,
                      threadID: threadID, turnID: turnID
                  ) else { continue }
            auditedPaths.append(record.relativePath)
        }
        let unauditedDeletions = before.entriesByPath.keys.filter { !seenPaths.contains($0) }.sorted()
        return ImportSummary(auditedPaths: auditedPaths, unauditedDeletions: unauditedDeletions, budgetExceeded: false)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    private static func isExcluded(_ relativePath: String) -> Bool {
        guard let topLevel = relativePath.split(separator: "/").first else { return false }
        return excludedTopLevelNames.contains(String(topLevel))
    }
}
