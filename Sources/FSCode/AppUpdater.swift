import AppKit
import Sparkle

@MainActor
enum AppUpdateConfiguration: Equatable {
    case unavailable(String)
    case ready(feedURL: URL, publicKey: String)

    static func from(bundle: Bundle) -> Self {
        configuration(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    static func configuration(feedURL: String?, publicKey: String?) -> Self {
        let feed = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (feed?.isEmpty == false ? feed : nil, key?.isEmpty == false ? key : nil) {
        case (nil, nil):
            return .unavailable("Updates are not configured for this build.")
        case (nil, _), (_, nil):
            return .unavailable("Updates require both a feed URL and public key.")
        case let (feed?, key?):
            guard let url = URL(string: feed), url.scheme == "https", url.host != nil else {
                return .unavailable("Updates require an HTTPS feed URL.")
            }
            guard Data(base64Encoded: key)?.count == 32 else {
                return .unavailable("Updates require a valid Ed25519 public key.")
            }
            return .ready(feedURL: url, publicKey: key)
        }
    }
}

@MainActor
final class AppUpdater {
    let configuration: AppUpdateConfiguration
    private let controller: SPUStandardUpdaterController?

    init(
        configuration: AppUpdateConfiguration = .from(bundle: .main),
        createsController: Bool = true
    ) {
        self.configuration = configuration
        if case .ready = configuration, createsController {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            controller = nil
        }
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = configuration else { return nil }
        return reason
    }

    func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}
