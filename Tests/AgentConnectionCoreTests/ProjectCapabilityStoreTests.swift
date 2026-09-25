import Foundation
import XCTest
@testable import AgentConnectionCore

final class ProjectCapabilityStoreTests: XCTestCase {
    func testCapabilitiesAreProjectScopedAndRevocable() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let a = ProjectCapabilityStore(projectURL: first, applicationSupportURL: support)
        let b = ProjectCapabilityStore(projectURL: second, applicationSupportURL: support)
        let initiallyEnabled = await a.isEnabled(.developmentCommands)
        XCTAssertFalse(initiallyEnabled)
        try await a.setEnabled(.developmentCommands, enabled: true)
        let enabled = await a.isEnabled(.developmentCommands)
        let otherEnabled = await b.isEnabled(.developmentCommands)
        XCTAssertTrue(enabled)
        XCTAssertFalse(otherEnabled)
        try await a.setEnabled(.developmentCommands, enabled: false)
        let revoked = await a.isEnabled(.developmentCommands)
        XCTAssertFalse(revoked)
    }

    func testRunnerUsesProjectDirectoryAndBoundsOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProjectCommandRunner(projectURL: root)
        let result = try await runner.run(arguments: ["/bin/pwd"], timeout: 2, maxOutputBytes: 4_096)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent,
            root.lastPathComponent
        )
        let capped = try await runner.run(arguments: ["/usr/bin/yes"], timeout: 0.05, maxOutputBytes: 128)
        XCTAssertLessThanOrEqual(capped.output.utf8.count, 128)
        XCTAssertTrue(capped.timedOut)
        XCTAssertTrue(capped.outputWasTruncated)
    }

    func testRunnerResolvesBareGitAndCanPushToLocalBareRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".git")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: remote) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProjectCommandRunner(projectURL: root)
        for command in [
            ["git", "init"],
            ["git", "config", "user.email", "tests@example.invalid"],
            ["git", "config", "user.name", "Tests"],
            ["/bin/sh", "-c", "printf test > file.txt"],
            ["git", "add", "file.txt"],
            ["git", "commit", "-m", "initial"],
            ["git", "branch", "-M", "main"]
        ] {
            let result = try await runner.run(arguments: command, timeout: 10)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.originalArguments, command)
        }
        let bare = try await runner.run(arguments: ["git", "init", "--bare", remote.path], timeout: 10)
        let addRemote = try await runner.run(arguments: ["git", "remote", "add", "origin", remote.path], timeout: 10)
        let push = try await runner.run(arguments: ["git", "push", "origin", "main"], timeout: 10)
        XCTAssertEqual(bare.exitCode, 0)
        XCTAssertEqual(addRemote.exitCode, 0)
        XCTAssertEqual(push.exitCode, 0)
    }

    func testRunnerFindsGitInFixedFallbackWhenPATHIsMinimal() {
        let resolved = ProjectCommandRunner.resolveExecutable("git", path: "/definitely/missing")
        XCTAssertEqual(resolved, "/usr/bin/git")
    }

    func testCancellingOneInvocationKillsItsChildrenWithoutAffectingAnother() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("child-marker")
        let started = root.appendingPathComponent("started")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProjectCommandRunner(projectURL: root)
        let runID = UUID()
        let cancelled = Task {
            try await runner.run(
                arguments: ["/bin/sh", "-c", "touch started; (sleep 1; touch child-marker) & wait"],
                runID: runID,
                timeout: 2
            )
        }
        let unaffected = Task {
            try await runner.run(arguments: ["/bin/sh", "-c", "sleep 0.1; printf unaffected"], timeout: 2)
        }
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        cancelled.cancel()
        let second = try await unaffected.value
        _ = try? await cancelled.value
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(second.output, "unaffected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFastOutputIsNotLostAcrossRepeatedRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProjectCommandRunner(projectURL: root)
        for index in 0..<20 {
            let result = try await runner.run(arguments: ["/bin/echo", "output-\(index)"], timeout: 2)
            XCTAssertEqual(result.output, "output-\(index)\n")
        }
    }

    func testRTKWrapsOnlyRecognizedDirectExecutables() {
        let rtk = "/tmp/rtk"
        let git = ProjectCommandRunner.effectiveArguments(for: ["/usr/bin/git", "status"], rtkExecutablePath: rtk)
        XCTAssertEqual(git.arguments, [rtk, "git", "status"])
        XCTAssertTrue(git.applied)
        let shell = ProjectCommandRunner.effectiveArguments(for: ["/bin/zsh", "-lc", "git status"], rtkExecutablePath: rtk)
        XCTAssertEqual(shell.arguments, ["/bin/zsh", "-lc", "git status"])
        XCTAssertFalse(shell.applied)
        let absent = ProjectCommandRunner.effectiveArguments(for: ["/usr/bin/git", "status"], rtkExecutablePath: nil)
        XCTAssertEqual(absent.arguments, ["/usr/bin/git", "status"])
        XCTAssertFalse(absent.applied)
    }

    func testRunnerRejectsUnresolvableAndRelativeExecutablePathsWithDiagnostic() async throws {
        XCTAssertNil(ProjectCommandRunner.resolveExecutable("missing-project-command", path: ".:/tmp::relative"))
        XCTAssertNil(ProjectCommandRunner.resolveExecutable("bin/git", path: "/usr/bin"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pathAlias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: pathAlias) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectExecutable = root.appendingPathComponent("project-only-command")
        FileManager.default.createFile(atPath: projectExecutable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectExecutable.path)
        try FileManager.default.createSymbolicLink(at: pathAlias, withDestinationURL: root)
        XCTAssertNil(ProjectCommandRunner.resolveExecutable("project-only-command", path: pathAlias.path, projectRoot: root))
        let runner = ProjectCommandRunner(projectURL: root)
        do {
            _ = try await runner.run(arguments: ["missing-project-command-\(UUID().uuidString)"])
            XCTFail("Missing executable was launched")
        } catch let error as ProjectCommandError {
            guard case let .unavailable(errno, message, executable) = error else { return XCTFail("Expected launch error") }
            XCTAssertEqual(errno, ENOENT)
            XCTAssertTrue(executable?.hasPrefix("missing-project-command-") == true)
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(error.errorDescription?.contains("errno \(ENOENT)"), true)
            XCTAssertTrue(error.errorDescription?.contains(executable ?? "") == true)
        }
    }
}
