import Foundation
import Testing
@testable import AgentConnectionCore

@Suite("System prompt editor persistence", .serialized)
struct SystemPromptEditorTests {
    @Test
    func savingOneSectionPreservesTheOtherSectionsAndAdvancesRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try AgentPromptStore(projectURL: project, applicationSupportURL: root)
        let original = try store.load()
        var changed = original
        changed.build = "Custom Build"
        changed.revision += 1
        try store.save(changed)
        let saved = try store.load()
        #expect(saved.build == "Custom Build")
        #expect(saved.shared == original.shared)
        #expect(saved.plan == original.plan)
        #expect(saved.ask == original.ask)
        #expect(saved.revision == original.revision + 1)
    }
}
