import Darwin
import Foundation

actor NativeProjectTools {
    let rootURL: URL
    init(rootURL: URL) { self.rootURL = rootURL }
    func execute(name: String, arguments: [String: String], mode: AgentMode = .ask, selectedPlanID: String? = nil) -> String {
        switch name {
        case "read_project_file":
            guard let path = arguments["relative_path"], let url = projectFile(path) else { return "Path is outside the project." }
            guard let text = readText(url) else { return "File is unavailable or not UTF-8 text." }
            return String(text.prefix(200_000))
        case "list_project_files":
            return projectFiles().joined(separator: "\n")
        case "search_project_text":
            guard let query = arguments["query"], !query.isEmpty, query.utf8.count <= 512 else { return "Search query was invalid." }
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
