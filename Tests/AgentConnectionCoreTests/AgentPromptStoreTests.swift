import Foundation
import Testing
@testable import AgentConnectionCore

@Suite("Agent prompt store", .serialized)
struct AgentPromptStoreTests {
    @Test func defaultsMatchCanonicalProfilesAndRoundTrip() throws {
        let source = try String(contentsOfFile: "docs/AGENT_PROFILES_V3_3.md")
        func section(_ name: String, _ next: String?) -> String {
            var value = source.components(separatedBy: "\n## \(name)\n")[1]
            if let next { value = value.components(separatedBy: "\n## \(next)\n")[0] }
            if value.hasSuffix("\n---\n") { value.removeLast(5) }
            value = String(value.drop(while: { $0 == "\n" }))
            if name == "Shared" { value = value.replacingOccurrences(of: "Include with every profile.\n\n", with: "") }
            return value.trimmingCharacters(in: .newlines)
        }
        #expect(AgentPromptStore.defaults.shared == section("Shared", "Build"))
        #expect(AgentPromptStore.defaults.build == section("Build", "Plan"))
        #expect(AgentPromptStore.defaults.plan == section("Plan", "Ask"))
        #expect(AgentPromptStore.defaults.ask == section("Ask", nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentPromptStore(projectIdentifier: "project", applicationSupportURL: root)
        var value = AgentPromptStore.defaults; value.revision = 2; value.ask = "custom"
        try store.save(value)
        #expect(try store.load() == value)
        try store.reset()
        #expect(try store.load() == AgentPromptStore.defaults)
    }
}
