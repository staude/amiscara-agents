#if os(iOS)
import UIKit

/// Asks iOS for a push token and leaves it on every host the app may write
/// files to (uploads on), where the Mac app picks it up (#94).
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    private(set) var token: String?
    /// Hosts and session generations the token was written for.
    private var written: Set<String> = []

    func start() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        written.removeAll()
    }

    /// Writes this device's registration on the host once per session.
    func register(on connection: HostConnection) {
        guard let token, connection.isLive, connection.config.uploadAllowed,
              let device = UIDevice.current.identifierForVendor?.uuidString
        else { return }
        let key = "\(connection.id)/\(connection.generation)"
        guard !written.contains(key) else { return }
        written.insert(key)
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let entry = PushDevice(
            token: token,
            environment: environment,
            hostID: connection.id,
            hostName: connection.config.name,
            deviceName: UIDevice.current.name,
            updated: .now
        )
        Task {
            do {
                try await connection.writePushRegistration(entry, fileName: "\(device).json")
            } catch {
                written.remove(key)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushRegistration.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Without push the local notifications still work while the app runs.
    }
}
#endif
