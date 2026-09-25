import XCTest
@testable import FSCode

@MainActor
final class AccessibilityPermissionGateTests: XCTestCase {
    func testDeniedPermissionRequestsOnceAndRequiresAnExplicitRetry() {
        var trusted = false
        var requests = 0
        let gate = AccessibilityPermissionGate(isTrusted: { trusted }, requestPermission: {
            requests += 1
        })
        XCTAssertFalse(gate.authorize())
        XCTAssertFalse(gate.authorize())
        XCTAssertEqual(requests, 1)
        trusted = true
        XCTAssertTrue(gate.authorize())
        XCTAssertEqual(requests, 1)
        trusted = false
        XCTAssertFalse(gate.authorize())
        XCTAssertEqual(requests, 1, "Revocation must block access without repeated prompts")
    }

    func testAlreadyTrustedDoesNotPrompt() {
        let gate = AccessibilityPermissionGate(isTrusted: { true }, requestPermission: {
            XCTFail("Trusted processes must not prompt")
        })
        XCTAssertTrue(gate.authorize())
    }

    func testGrantDuringRequestDoesNotAuthorizePendingOperation() {
        var trusted = false
        let gate = AccessibilityPermissionGate(isTrusted: { trusted }, requestPermission: {
            trusted = true
        })
        XCTAssertFalse(gate.authorize())
        XCTAssertTrue(gate.authorize())
    }
}
