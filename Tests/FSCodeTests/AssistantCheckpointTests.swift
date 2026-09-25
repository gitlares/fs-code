import XCTest
@testable import FSCode

final class AssistantCheckpointTests: XCTestCase {
    private let footer = """
    ## Checkpoint

    - Objective: Improve the transcript
    - Plan: Keep the footer structured
    - Changes made: Added a disclosure
    - Verified: Parser test
    - Not verified: Visual review
    - Discarded hypotheses: None
    - Next action: Resize the assistant pane and review the result
    """

    func testExtractsBulletCheckpointAtMessageSuffix() throws {
        let checkpoint = try XCTUnwrap(AssistantCheckpoint.extract(from: "Visible response.\n\n\(footer)"))
        XCTAssertEqual(checkpoint.body, "Visible response.")
        XCTAssertEqual(checkpoint.meaningfulNextAction, "Resize the assistant pane and review the result")
    }

    func testPartialFooterAndCodeFenceAreLeftUntouched() {
        XCTAssertNil(AssistantCheckpoint.extract(from: "Answer\n\n## Checkpoint\n- Objective: Only one field"))
        XCTAssertNil(AssistantCheckpoint.extract(from: "```markdown\n\(footer)\n```"))
    }

    func testHidesKnownAbsentNextActionButPreservesRealAction() throws {
        for absence in ["None", "Ninguno", "Ninguna", "N/A", "—", ""] {
            let source = footer.replacingOccurrences(of: "Resize the assistant pane and review the result", with: absence)
            XCTAssertNil(try XCTUnwrap(AssistantCheckpoint.extract(from: source)).meaningfulNextAction)
        }
        XCTAssertNotNil(try XCTUnwrap(AssistantCheckpoint.extract(from: footer)).meaningfulNextAction)
    }
}
