#if os(macOS)
import Foundation
import Sparkle

/// Owns Sparkle for the Mac app, which comes with Developer ID from GitHub
/// rather than the App Store. Offers only what the menu and the settings
/// need: check automatically or not, and check now. Modeled on TorroMail
/// and Kastellan.
///
/// Sparkle checks at start and then every 24 hours
/// (`SUScheduledCheckInterval`) against the appcast in the release
/// `updates`, loads a new version in the background and installs it when
/// the app quits. Debug builds and bundles without a real public key stay
/// silent: a development build must not replace itself with a release.
@Observable
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init(bundle: Bundle = .main) {
        if Self.canStart(in: bundle) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    var isAvailable: Bool { controller != nil }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private static func canStart(in bundle: Bundle) -> Bool {
        #if DEBUG
        return false
        #else
        guard bundle.bundlePath.hasSuffix(".app"),
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, !key.hasPrefix("__") else { return false }
        return true
        #endif
    }
}
#endif
