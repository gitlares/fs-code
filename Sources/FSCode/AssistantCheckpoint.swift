import Foundation

struct AssistantCheckpoint: Equatable {
    struct Field: Equatable { let label: String; let value: String }
    static let labels = ["Objective", "Plan", "Changes made", "Verified", "Not verified", "Discarded hypotheses", "Next action"]
    let body: String
    let fields: [Field]

    var meaningfulNextAction: String? {
        guard let value = fields.first(where: { $0.label == "Next action" })?.value else { return nil }
        let token = value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return ["", "none", "ninguno", "ninguna", "na"].contains(token) ? nil : value
    }

    static func extract(from source: String) -> AssistantCheckpoint? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenceCount = 0
        var start: Int?
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenceCount += 1 }
            guard fenceCount.isMultiple(of: 2), line == "Checkpoint" || line == "## Checkpoint" else { continue }
            start = index
        }
        guard let start else { return nil }
        var values: [String: String] = [:]
        for rawLine in lines[(start + 1)...] {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let content = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
            guard let colon = content.firstIndex(of: ":") else { return nil }
            let label = String(content[..<colon])
            guard labels.contains(label), values[label] == nil else { return nil }
            values[label] = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard values.count == labels.count else { return nil }
        let body = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantCheckpoint(body: body, fields: labels.map { Field(label: $0, value: values[$0]!) })
    }
}
