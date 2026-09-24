import CryptoKit
import Foundation
import Testing
@testable import AgentConnectionCore

@Suite("Agent file change service", .serialized)
struct AgentFileChangeServiceTests {
    @Test
    func stagingDoesNotWriteThenApplyAndRevertRemainAudited() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("let value = 1\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let service = try AgentFileChangeService(projectURL: project)

        let proposal = try await service.stageEdit(
            relativePath: "Sources/App.swift",
            oldText: "value = 1",
            newText: "value = 2",
            threadID: "thread-1",
            turnID: "turn-1"
        )

        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".fscode").path))
        #expect(proposal.diff.contains("-let value = 1"))
        #expect(proposal.diff.contains("+let value = 2"))

        let applied = try await service.applyApproved(proposal)
        #expect(applied.status == .applied)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 2\n")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue == 0o640)
        #expect(try await service.history(relativePath: "Sources/App.swift").count == 1)

        let reverted = try await service.revert(recordID: applied.id)
        #expect(reverted.status == .reverted)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
        let history = try await service.history(relativePath: "Sources/App.swift")
        #expect(history.first?.status == .reverted)
        #expect(history.first?.beforeSHA256 == proposal.beforeSHA256)
        #expect(history.first?.afterSHA256 == proposal.afterSHA256)
    }

    @Test
    func createsOnlyAbsentFilesAndRevertRemovesTheCreatedFile() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "Sources/New.swift",
            oldText: "",
            newText: "struct New {}\n",
            threadID: "thread",
            turnID: "turn"
        )
        let target = project.appendingPathComponent("Sources/New.swift")
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let applied = try await service.applyApproved(proposal)
        #expect(try String(contentsOf: target, encoding: .utf8) == "struct New {}\n")
        _ = try await service.revert(recordID: applied.id)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func rejectsExternalChangesAmbiguousTextAndSymlinks() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("File.txt")
        try Data("same same\n".utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)

        do {
            _ = try await service.stageEdit(
                relativePath: "File.txt",
                oldText: "same",
                newText: "other",
                threadID: "thread",
                turnID: "turn"
            )
            Issue.record("Expected an ambiguous replacement")
        } catch {
            #expect(error as? AgentFileChangeError == .ambiguousReplacement)
        }

        try Data("aaa".utf8).write(to: file, options: .atomic)
        do {
            _ = try await service.stageEdit(
                relativePath: "File.txt",
                oldText: "aa",
                newText: "b",
                threadID: "thread",
                turnID: "turn"
            )
            Issue.record("Expected overlapping matches to be ambiguous")
        } catch {
            #expect(error as? AgentFileChangeError == .ambiguousReplacement)
        }
        try Data("same same\n".utf8).write(to: file, options: .atomic)

        let proposal = try await service.stageEdit(
            relativePath: "File.txt",
            oldText: "same same",
            newText: "changed",
            threadID: "thread",
            turnID: "turn"
        )
        try Data("external\n".utf8).write(to: file, options: .atomic)
        do {
            _ = try await service.applyApproved(proposal)
            Issue.record("Expected an external change conflict")
        } catch {
            #expect(error as? AgentFileChangeError == .externalChange)
        }

        let outside = project.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("link.txt"),
            withDestinationURL: outside
        )
        do {
            _ = try await service.read(relativePath: "link.txt")
            Issue.record("Expected a symlink rejection")
        } catch {
            #expect(error as? AgentFileChangeError == .symlinkNotAllowed)
        }

        do {
            _ = try await service.stageEdit(
                relativePath: ".GIT/config",
                oldText: "",
                newText: "unsafe",
                threadID: "thread",
                turnID: "turn"
            )
            Issue.record("Expected Git metadata to be protected case-insensitively")
        } catch {
            #expect(error as? AgentFileChangeError == .protectedPath)
        }
    }

    @Test
    func separatedHunksRevertInEitherOrderAndPreserveShiftedManualEdits() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("File.txt")
        let before = [
            "top", "first old", "keep 1", "keep 2", "keep 3", "keep 4",
            "keep 5", "keep 6", "keep 7", "keep 8", "keep 9", "keep 10",
            "second old", "bottom",
        ].joined(separator: "\r\n") + "\r\n"
        let after = before
            .replacingOccurrences(of: "first old", with: "first new")
            .replacingOccurrences(of: "second old", with: "second new")
        try Data(before.utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "File.txt",
            oldText: before,
            newText: after,
            threadID: "thread",
            turnID: "turn"
        )
        let applied = try await service.applyApproved(proposal)
        #expect(applied.changeHunks.count == 2)
        #expect(applied.changeHunks.allSatisfy { $0.beforeLineCount == 1 && $0.afterLineCount == 1 })

        let withManualEdit = after.replacingOccurrences(
            of: "keep 4\r\n",
            with: "keep 4\r\nmanual note 🙂\r\n"
        )
        try Data(withManualEdit.utf8).write(to: file, options: .atomic)

        let reloaded = try AgentFileChangeService(projectURL: project)
        let persisted = try #require(try await reloaded.history().first)
        let second = try #require(persisted.changeHunks.first { $0.beforeText.contains("second old") })
        let secondRange = try #require(second.locate(in: withManualEdit))
        #expect((withManualEdit as NSString).substring(with: secondRange) == second.afterText)
        let afterSecondRevert = try await reloaded.revertHunk(
            recordID: applied.id,
            hunkID: second.id
        )
        #expect(afterSecondRevert.status == .applied)
        var current = try String(contentsOf: file, encoding: .utf8)
        #expect(current.contains("first new"))
        #expect(current.contains("second old"))
        #expect(current.contains("manual note 🙂"))

        let reloadedAgain = try AgentFileChangeService(projectURL: project)
        let partial = try #require(try await reloadedAgain.history().first)
        #expect(partial.changeHunks.filter(\.isReverted).count == 1)
        let first = try #require(partial.changeHunks.first { !$0.isReverted })
        let final = try await reloadedAgain.revertHunk(recordID: applied.id, hunkID: first.id)
        #expect(final.status == .reverted)
        current = try String(contentsOf: file, encoding: .utf8)
        #expect(current.contains("first old"))
        #expect(current.contains("second old"))
        #expect(current.contains("manual note 🙂"))
        #expect(!current.contains("first new"))
        #expect(!current.contains("second new"))
    }

    @Test
    func deletionInsertionAndNewFileHunksRevertConservatively() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let service = try AgentFileChangeService(projectURL: project)

        let file = project.appendingPathComponent("Unicode.txt")
        let before = "a\r\nremove 🙂\r\nb\r\n"
        try Data(before.utf8).write(to: file)
        let deletion = try await service.stageEdit(
            relativePath: "Unicode.txt",
            oldText: "remove 🙂\r\n",
            newText: "",
            threadID: "thread",
            turnID: "delete"
        )
        let deleted = try await service.applyApproved(deletion)
        let deletionHunk = try #require(deleted.changeHunks.first)
        #expect(deletionHunk.afterText.isEmpty)
        try Data("a\r\nb\r\nmanual\r\n".utf8).write(to: file, options: .atomic)
        _ = try await service.revertHunk(recordID: deleted.id, hunkID: deletionHunk.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == before + "manual\r\n")

        let insertion = try await service.stageEdit(
            relativePath: "Unicode.txt",
            oldText: "b\r\n",
            newText: "inserted 漢字\r\nb\r\n",
            threadID: "thread",
            turnID: "insert"
        )
        let inserted = try await service.applyApproved(insertion)
        let insertionHunk = try #require(inserted.changeHunks.first)
        #expect(insertionHunk.beforeText.isEmpty)
        _ = try await service.revertHunk(recordID: inserted.id, hunkID: insertionHunk.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == before + "manual\r\n")

        let createdProposal = try await service.stageEdit(
            relativePath: "New.txt",
            oldText: "",
            newText: "agent content\n",
            threadID: "thread",
            turnID: "create"
        )
        let created = try await service.applyApproved(createdProposal)
        let createHunk = try #require(created.changeHunks.first)
        let newFile = project.appendingPathComponent("New.txt")
        try Data("agent content\nuser content\n".utf8).write(to: newFile, options: .atomic)
        _ = try await service.revertHunk(recordID: created.id, hunkID: createHunk.id)
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        #expect(try String(contentsOf: newFile, encoding: .utf8) == "user content\n")

        let cleanProposal = try await service.stageEdit(
            relativePath: "CleanNew.txt",
            oldText: "",
            newText: "agent content\n",
            threadID: "thread",
            turnID: "clean-create"
        )
        let cleanRecord = try await service.applyApproved(cleanProposal)
        let cleanHunk = try #require(cleanRecord.changeHunks.first)
        _ = try await service.revertHunk(recordID: cleanRecord.id, hunkID: cleanHunk.id)
        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent("CleanNew.txt").path
        ))

        let emptyProposal = try await service.stageEdit(
            relativePath: "Empty.txt",
            oldText: "",
            newText: "",
            threadID: "thread",
            turnID: "empty-create"
        )
        let emptyRecord = try await service.applyApproved(emptyProposal)
        let emptyHunk = try #require(emptyRecord.changeHunks.first)
        #expect(emptyHunk.beforeLineCount == 0)
        #expect(emptyHunk.afterLineCount == 0)
        _ = try await service.revertHunk(recordID: emptyRecord.id, hunkID: emptyHunk.id)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Empty.txt").path))
    }

    @Test
    func ambiguousHunkPlacementIsRejectedWithoutWriting() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("Repeated.txt")
        let before = "p1\np2\np3\nold\ns1\ns2\ns3\nseparator\np1\np2\np3\nnew\ns1\ns2\ns3\n"
        try Data(before.utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "Repeated.txt",
            oldText: "old\n",
            newText: "new\n",
            threadID: "thread",
            turnID: "turn"
        )
        let applied = try await service.applyApproved(proposal)
        let hunk = try #require(applied.changeHunks.first)
        let duplicated = try String(contentsOf: file, encoding: .utf8)
        #expect(hunk.locate(in: duplicated) == nil)
        do {
            _ = try await service.revertHunk(recordID: applied.id, hunkID: hunk.id)
            Issue.record("Expected ambiguous hunk placement to be rejected")
        } catch {
            #expect(error as? AgentFileChangeError == .revertUnavailable)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == duplicated)
    }

    @Test
    func legacyJournalLoadsAndLargeDiffFallsBackToOneHunk() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("Large.txt")
        let beforeLines = (0...1_000).map { "line \($0)\n" }
        var afterLines = beforeLines
        afterLines[10] = "changed ten\n"
        afterLines[990] = "changed nine ninety\n"
        let before = beforeLines.joined()
        let after = afterLines.joined()
        try Data(before.utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "Large.txt",
            oldText: before,
            newText: after,
            threadID: "thread",
            turnID: "turn"
        )
        let applied = try await service.applyApproved(proposal)
        #expect(applied.changeHunks.count == 1)

        let journal = await service.journalURL
            .appendingPathComponent(applied.id.uuidString + ".json")
        let data = try Data(contentsOf: journal)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "changeHunks")
        object.removeValue(forKey: "pendingHunkRevert")
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)

        let reloaded = try AgentFileChangeService(projectURL: project)
        let legacy = try #require(try await reloaded.history().first)
        #expect(legacy.changeHunks.count == 1)
        #expect(legacy.changeHunks[0].id == applied.changeHunks[0].id)

        do {
            _ = try await reloaded.stageEdit(
                relativePath: "Large.txt",
                oldText: after,
                newText: after,
                threadID: "thread",
                turnID: "no-op"
            )
            Issue.record("Expected a no-op edit to be rejected")
        } catch {
            #expect(error as? AgentFileChangeError == .noChanges)
        }
    }

    @Test
    func preparedPartialRevertRecoversAfterRelaunch() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("Recover.txt")
        let before = "top\nfirst old\nkeep 1\nkeep 2\nkeep 3\nsecond old\nbottom\n"
        let after = before
            .replacingOccurrences(of: "first old", with: "first new")
            .replacingOccurrences(of: "second old", with: "second new")
        try Data(before.utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let proposal = try await service.stageEdit(
            relativePath: "Recover.txt",
            oldText: before,
            newText: after,
            threadID: "thread",
            turnID: "turn"
        )
        let applied = try await service.applyApproved(proposal)
        let first = try #require(applied.changeHunks.first)
        _ = try await service.revertHunk(recordID: applied.id, hunkID: first.id)
        let partiallyRevertedText = try String(contentsOf: file, encoding: .utf8)

        let journal = await service.journalURL
            .appendingPathComponent(applied.id.uuidString + ".json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any]
        )
        var hunks = try #require(object["changeHunks"] as? [[String: Any]])
        let hunkIndex = try #require(hunks.firstIndex { $0["id"] as? String == first.id })
        hunks[hunkIndex]["isReverted"] = false
        object["changeHunks"] = hunks
        object["status"] = AgentFileChangeStatus.applied.rawValue
        object["pendingHunkRevert"] = [
            "hunkID": first.id,
            "beforeSHA256": applied.afterSHA256,
            "afterSHA256": sha256(partiallyRevertedText),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)

        let reloaded = try AgentFileChangeService(projectURL: project)
        let recovered = try #require(try await reloaded.history().first)
        #expect(recovered.status == .applied)
        #expect(recovered.changeHunks.first { $0.id == first.id }?.isReverted == true)
        #expect(recovered.changeHunks.filter(\.isReverted).count == 1)
    }

    @Test
    func restorePointRewindsAllLaterSameChatEditsAndPersistsItsStatus() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let alpha = project.appendingPathComponent("Alpha.txt")
        let beta = project.appendingPathComponent("Beta.txt")
        try Data("zero\n".utf8).write(to: alpha)
        try Data("old\n".utf8).write(to: beta)
        let service = try AgentFileChangeService(projectURL: project)

        let first = try await service.stageEdit(relativePath: "Alpha.txt", oldText: "zero", newText: "one", threadID: "chat", turnID: "first")
        _ = try await service.applyApproved(first)
        let second = try await service.stageEdit(relativePath: "Beta.txt", oldText: "old", newText: "new", threadID: "chat", turnID: "first")
        _ = try await service.applyApproved(second)
        let duplicatePath = try await service.stageEdit(relativePath: "Alpha.txt", oldText: "one", newText: "two", threadID: "chat", turnID: "first")
        _ = try await service.applyApproved(duplicatePath)
        let later = try await service.stageEdit(relativePath: "Alpha.txt", oldText: "two", newText: "three", threadID: "chat", turnID: "later")
        _ = try await service.applyApproved(later)

        #expect(try await service.restorePointPaths(threadID: "chat", turnID: "first") == ["Alpha.txt", "Beta.txt"])
        let restored = try await service.restorePoint(threadID: "chat", turnID: "first")
        #expect(restored.count == 4)
        #expect(try String(contentsOf: alpha, encoding: .utf8) == "zero\n")
        #expect(try String(contentsOf: beta, encoding: .utf8) == "old\n")

        let reloaded = try AgentFileChangeService(projectURL: project)
        let history = try await reloaded.history()
        #expect(history.filter { $0.threadID == "chat" }.allSatisfy { $0.status == .restored })
    }

    @Test
    func restorePointPreflightConflictDoesNotMutateAnyOtherFile() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let alpha = project.appendingPathComponent("Alpha.txt")
        let beta = project.appendingPathComponent("Beta.txt")
        try Data("alpha before\n".utf8).write(to: alpha)
        try Data("beta before\n".utf8).write(to: beta)
        let service = try AgentFileChangeService(projectURL: project)
        let alphaChange = try await service.stageEdit(relativePath: "Alpha.txt", oldText: "before", newText: "after", threadID: "chat", turnID: "turn")
        _ = try await service.applyApproved(alphaChange)
        let betaChange = try await service.stageEdit(relativePath: "Beta.txt", oldText: "before", newText: "after", threadID: "chat", turnID: "turn")
        _ = try await service.applyApproved(betaChange)
        try Data("user edit\n".utf8).write(to: beta, options: .atomic)

        do {
            _ = try await service.restorePoint(threadID: "chat", turnID: "turn")
            Issue.record("Expected an external change conflict")
        } catch {
            #expect(error as? AgentFileChangeError == .externalChange)
        }
        #expect(try String(contentsOf: alpha, encoding: .utf8) == "alpha after\n")
        #expect(try String(contentsOf: beta, encoding: .utf8) == "user edit\n")
    }

    @Test
    func restorePointDeletesFilesCreatedByTheChat() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let service = try AgentFileChangeService(projectURL: project)
        let created = try await service.stageEdit(relativePath: "Generated.txt", oldText: "", newText: "agent file\n", threadID: "chat", turnID: "turn")
        _ = try await service.applyApproved(created)

        _ = try await service.restorePoint(threadID: "chat", turnID: "turn")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Generated.txt").path))
    }

    @Test
    func restorePointCanRewindPastAnAlreadyRestoredLaterTurn() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("File.txt")
        try Data("zero".utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let first = try await service.stageEdit(relativePath: "File.txt", oldText: "zero", newText: "one", threadID: "chat", turnID: "one")
        _ = try await service.applyApproved(first)
        let second = try await service.stageEdit(relativePath: "File.txt", oldText: "one", newText: "two", threadID: "chat", turnID: "two")
        _ = try await service.applyApproved(second)

        _ = try await service.restorePoint(threadID: "chat", turnID: "two")
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        _ = try await service.restorePoint(threadID: "chat", turnID: "one")
        #expect(try String(contentsOf: file, encoding: .utf8) == "zero")
    }

    @Test
    func restorePointRejectsAStillAppliedLaterEditFromAnotherChat() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("File.txt")
        try Data("zero".utf8).write(to: file)
        let service = try AgentFileChangeService(projectURL: project)
        let first = try await service.stageEdit(relativePath: "File.txt", oldText: "zero", newText: "one", threadID: "chat-a", turnID: "one")
        _ = try await service.applyApproved(first)
        let other = try await service.stageEdit(relativePath: "File.txt", oldText: "one", newText: "two", threadID: "chat-b", turnID: "other")
        _ = try await service.applyApproved(other)

        do {
            _ = try await service.restorePoint(threadID: "chat-a", turnID: "one")
            Issue.record("Expected another chat's later edit to block restoration")
        } catch {
            #expect(error as? AgentFileChangeError == .restoreUnavailable)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
