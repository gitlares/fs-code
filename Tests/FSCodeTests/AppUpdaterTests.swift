import AppKit
import XCTest
@testable import FSCode

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testMissingConfigurationLeavesUpdaterUnavailable() {
        XCTAssertEqual(
            AppUpdateConfiguration.configuration(feedURL: nil, publicKey: nil),
            .unavailable("Updates are not configured for this build.")
        )
        let updater = AppUpdater(
            configuration: .unavailable("Updates are not configured for this build."),
            createsController: false
        )
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.unavailableReason, "Updates are not configured for this build.")
        updater.checkForUpdates(nil)
    }

    func testPartialOrInvalidConfigurationDoesNotEnableUpdates() {
        XCTAssertEqual(
            AppUpdateConfiguration.configuration(
                feedURL: "https://updates.example.com/appcast.xml",
                publicKey: nil
            ),
            .unavailable("Updates require both a feed URL and public key.")
        )
        XCTAssertEqual(
            AppUpdateConfiguration.configuration(
                feedURL: "http://updates.example.com/appcast.xml",
                publicKey: validPublicKey
            ),
            .unavailable("Updates require an HTTPS feed URL.")
        )
        XCTAssertEqual(
            AppUpdateConfiguration.configuration(
                feedURL: "https://updates.example.com/appcast.xml",
                publicKey: "not-a-key"
            ),
            .unavailable("Updates require a valid Ed25519 public key.")
        )
    }

    func testValidConfigurationIsRecognizedWithoutStartingUpdater() {
        let expectedURL = URL(string: "https://updates.example.com/appcast.xml")!
        XCTAssertEqual(
            AppUpdateConfiguration.configuration(
                feedURL: expectedURL.absoluteString,
                publicKey: validPublicKey
            ),
            .ready(feedURL: expectedURL, publicKey: validPublicKey)
        )
        let updater = AppUpdater(
            configuration: .ready(feedURL: expectedURL, publicKey: validPublicKey),
            createsController: false
        )
        XCTAssertFalse(updater.canCheckForUpdates, "Command-line tests never start Sparkle")
    }

    private var validPublicKey: String {
        Data(repeating: 0xA5, count: 32).base64EncodedString()
    }
}
