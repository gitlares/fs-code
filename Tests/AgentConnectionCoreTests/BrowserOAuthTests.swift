import Foundation
import XCTest
@testable import AgentConnectionCore

final class BrowserOAuthTests: XCTestCase {
    func testPKCEChallengeUsesS256() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            BrowserOAuth.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let random = try? BrowserOAuth.randomURLSafeString(byteCount: 32)
        XCTAssertEqual(random?.count, 43)
        XCTAssertFalse(random?.contains("=") ?? true)
    }

    func testCallbackAcceptsMatchingStateAfterRejectingIncorrectState() async throws {
        let (listener, port) = try makeListener()
        defer { listener.cancel() }
        let codeTask = Task { try await listener.waitForCode() }

        let rejected = try await request(port: port, path: "/auth/callback?code=bad&state=other")
        XCTAssertEqual(rejected.statusCode, 400)
        let accepted = try await request(port: port, path: "/auth/callback?code=good%20code&state=expected")
        XCTAssertEqual(accepted.statusCode, 200)
        let received = try await codeTask.value
        XCTAssertEqual(received, "good code")
    }

    func testCancelReleasesListenerAndFailsWaiter() async throws {
        let (listener, port) = try makeListener()
        defer { listener.cancel() }
        let codeTask = Task { try await listener.waitForCode() }
        listener.cancel()
        do {
            _ = try await codeTask.value
            XCTFail("Expected cancellation")
        } catch let error as BrowserAuthorizationError {
            XCTAssertEqual(error, .cancelled)
        }

        var replacement: LoopbackCallbackListener?
        for _ in 0..<100 {
            replacement = try? LoopbackCallbackListener(expectedState: "replacement", port: port)
            if replacement != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(replacement, "Cancelled listener must release its port promptly")
        replacement?.cancel()
    }

    func testPortBusyUsesSanitizedError() throws {
        let (listener, port) = try makeListener()
        defer { listener.cancel() }
        XCTAssertThrowsError(try LoopbackCallbackListener(expectedState: "other", port: port)) { error in
            XCTAssertEqual(error as? BrowserAuthorizationError, .portBusy)
            XCTAssertEqual(error.localizedDescription, "Browser authorization cannot start because its local callback port is in use.")
        }
    }

    func testProviderDenialWithMatchingStateEndsAuthorization() async throws {
        let (listener, port) = try makeListener()
        defer { listener.cancel() }
        let codeTask = Task { try await listener.waitForCode() }
        let response = try await request(port: port, path: "/auth/callback?error=access_denied&state=expected")
        XCTAssertEqual(response.statusCode, 400)
        do {
            _ = try await codeTask.value
            XCTFail("Expected denial")
        } catch let error as BrowserAuthorizationError {
            XCTAssertEqual(error, .denied)
        }
    }

    private func makeListener() throws -> (LoopbackCallbackListener, UInt16) {
        for port in UInt16(20_000)...UInt16(20_100) {
            if let listener = try? LoopbackCallbackListener(expectedState: "expected", port: port) {
                return (listener, port)
            }
        }
        throw BrowserAuthorizationError.unavailable
    }

    private func request(port: UInt16, path: String) async throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        let (_, response) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(response as? HTTPURLResponse)
    }
}
