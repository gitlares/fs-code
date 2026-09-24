import Foundation
import XCTest
@testable import FSCode

final class ShellIntegrationTests: XCTestCase {
    private func runZsh(rc: String, noColor: Bool = false, color: String = "1", command: String? = nil) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FS Code zsh \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export FSCODE_TEST_ZSHENV=once\nexport FSCODE_TEST_TRACE=\"${FSCODE_TEST_TRACE}zshenv,\"\n".data(using: .utf8)!.write(to: root.appendingPathComponent(".zshenv"))
        try "export FSCODE_TEST_TRACE=\"${FSCODE_TEST_TRACE}zprofile,\"\n".data(using: .utf8)!.write(to: root.appendingPathComponent(".zprofile"))
        try rc.data(using: .utf8)!.write(to: root.appendingPathComponent(".zshrc"))
        try "export FSCODE_TEST_TRACE=\"${FSCODE_TEST_TRACE}zlogin,\"\n".data(using: .utf8)!.write(to: root.appendingPathComponent(".zlogin"))
        let integration = try XCTUnwrap(ShellIntegration.make(for: "/bin/zsh"))
        defer { integration.remove() }

        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = integration.directory.path
        environment["FSCODE_ZSH_BOOTSTRAP"] = "1"
        environment["FSCODE_ORIGINAL_ZDOTDIR"] = root.path
        environment["FSCODE_HAS_ORIGINAL_ZDOTDIR"] = "1"
        environment["FSCODE_DEFAULT_CLICOLOR"] = "1"
        environment["CLICOLOR"] = color
        environment.removeValue(forKey: "NO_COLOR")
        if noColor { environment["NO_COLOR"] = "1" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-l", "-c", command ?? "_fscode_prompt_once; print -r -- \"$FSCODE_TEST_ZSHENV|$PROMPT|$CLICOLOR|${precmd_functions[*]}\""]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    }

    func testStockPromptInstallsAfterOriginalStartupAndRemovesHook() throws {
        let output = try runZsh(rc: "PROMPT='%n@%m %1~ %# '\n")
        XCTAssertTrue(output.contains("once|%F{4}%1~%f %(?.%F{2}%#%f.%F{1}[%?] %#%f) |1|"), output)
        XCTAssertFalse(output.contains("_fscode_prompt_once"))
    }

    func testCustomPromptAndPrecmdArePreserved() throws {
        let custom = try runZsh(rc: "PROMPT='custom> '\n")
        XCTAssertTrue(custom.contains("once|custom> |1|"), custom)
        let hooked = try runZsh(rc: "precmd() { :; }\n")
        XCTAssertTrue(hooked.contains("%n@%m %1~ %# "), hooked)
    }

    func testNoColorSkipsPromptAndWithdrawsDefaultCLICOLOR() throws {
        let output = try runZsh(rc: "export NO_COLOR=1\nPROMPT='%n@%m %1~ %# '\n")
        XCTAssertTrue(output.contains("once|%n@%m %1~ %# ||"))
    }

    func testLoginStartupUsesOriginalDotfilesOnceAndDoesNotExportBootstrap() throws {
        let output = try runZsh(
            rc: "export FSCODE_TEST_TRACE=\"${FSCODE_TEST_TRACE}zshrc,\"\n",
            command: "_fscode_prompt_once; print -r -- \"$FSCODE_TEST_TRACE|$ZDOTDIR\"; env | grep FSCODE || true"
        )
        XCTAssertTrue(output.contains("zshenv,zprofile,zshrc,zlogin,|"), output)
        XCTAssertFalse(output.contains("FSCODE_ZSH_"), output)
        XCTAssertFalse(output.contains("FSCODE_ORIGINAL_"), output)
    }

    func testRenderedPromptShowsAnsiAndFailureStatus() throws {
        let output = try runZsh(
            rc: "PROMPT='%n@%m %1~ %# '\n",
            command: "false; _fscode_prompt_once; print -P -- \"$PROMPT\""
        )
        XCTAssertTrue(output.contains("\u{001B}["), output)
        XCTAssertTrue(output.contains("[1]"), output)
    }

    func testNoColorPreservesAUserChangedCLICOLORValue() throws {
        let output = try runZsh(rc: "export NO_COLOR=1\n", noColor: false, color: "0")
        XCTAssertTrue(output.contains("once|%n@%m %1~ %# |0|"), output)
    }
}
