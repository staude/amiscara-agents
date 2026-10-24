#if !os(tvOS)
import Foundation
import LocalAuthentication
import Observation

/// Optional lock with Face ID, Touch ID or the device passcode (#232): the
/// app can run commands on the user's machines. Off by default. Coming back
/// after `delay`, the content stays covered until unlocked; while the app
/// is not active it is covered too, so the app switcher shows nothing.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    static let enabledKey = "appLock"
    static let delayKey = "appLockDelay"

    /// Seconds in the background before the lock applies again.
    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .immediately: "Sofort"
            case .oneMinute: "Nach 1 Minute"
            case .fiveMinutes: "Nach 5 Minuten"
            }
        }
    }

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var failure: String?
    private var leftAt: Date?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Locked from the start: a cold launch counts as coming back.
        isLocked = defaults.bool(forKey: Self.enabledKey) && !DemoMode.isOn
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) && !DemoMode.isOn }

    var delay: Delay { Delay(rawValue: defaults.integer(forKey: Self.delayKey)) ?? .immediately }

    /// Whether this device can check the owner at all (biometrics or a
    /// passcode); without one the setting cannot be turned on.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func didLeave() {
        guard isEnabled, !isLocked else { return }
        leftAt = .now
    }

    /// Back in the foreground: locks once the delay is over and asks at once.
    func didReturn() {
        guard isEnabled else {
            isLocked = false
            return
        }
        if let leftAt, Date.now.timeIntervalSince(leftAt) >= Double(delay.rawValue) {
            isLocked = true
        }
        leftAt = nil
        if isLocked { unlock() }
    }

    /// Turning the setting off unlocks; turning it on does not lock the
    /// running app, only the next return.
    func settingChanged() {
        if !isEnabled { isLocked = false }
    }

    func unlock() {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        failure = nil
        let context = LAContext()
        let reason = String(localized: "Amiscara Agents entsperren")
        Task {
            defer { isAuthenticating = false }
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
                    isLocked = false
                }
            } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
                // Stays locked; the button asks again.
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
#endif
