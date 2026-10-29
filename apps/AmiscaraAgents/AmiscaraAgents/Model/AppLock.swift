#if !os(tvOS)
import Foundation
import LocalAuthentication
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Optional lock with Face ID, Touch ID or the device passcode (#232): the
/// app can run commands on the user's machines. Off by default. Coming back
/// after `delay`, the content stays covered until unlocked; on iOS it is
/// covered while the app is not active too, so the app switcher shows
/// nothing. Follows the app as a whole (`start`), not single windows or
/// scenes: the Mac app runs on without a window, the iPad has several.
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
    /// The app is in front; on iOS the cover also shows while it is not.
    private(set) var isActive = true
    /// Ask once when the app becomes active after a return, not again
    /// after a cancelled prompt (which makes the app active again too).
    private var promptPending: Bool
    private var observers: [NSObjectProtocol] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Locked from the start: a cold launch counts as coming back.
        let locked = defaults.bool(forKey: Self.enabledKey) && !DemoMode.isOn
        isEnabled = locked
        isLocked = locked
        promptPending = locked
    }

    /// What the cover shows over: locked, or on iOS not in front.
    var isCovered: Bool {
        guard isEnabled else { return false }
        #if os(iOS)
        return isLocked || !isActive
        #else
        return isLocked
        #endif
    }

    /// Follows the app's activation once, from the app's start.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (AppLock) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }
        #if os(iOS)
        on(UIApplication.didEnterBackgroundNotification) { $0.didLeave() }
        on(UIApplication.willEnterForegroundNotification) { $0.didReturn() }
        on(UIApplication.willResignActiveNotification) { $0.isActive = false }
        on(UIApplication.didBecomeActiveNotification) { $0.becameActive() }
        #elseif os(macOS)
        on(NSApplication.didResignActiveNotification) { $0.didLeave() }
        on(NSApplication.didBecomeActiveNotification) {
            $0.didReturn()
            $0.becameActive()
        }
        #endif
    }

    private func becameActive() {
        isActive = true
        if promptPending {
            promptPending = false
            if isLocked { unlock() }
        }
    }

    /// Stored, so views that read the lock follow the setting.
    private(set) var isEnabled: Bool

    var delay: Delay { Delay(rawValue: defaults.integer(forKey: Self.delayKey)) ?? .immediately }

    /// Whether this device can check the owner at all (biometrics or a
    /// passcode); without one the setting cannot be turned on.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private func didLeave() {
        guard isEnabled, !isLocked else { return }
        leftAt = .now
    }

    /// Back in the foreground: locks once the delay is over and asks at once.
    private func didReturn() {
        guard isEnabled else {
            isLocked = false
            return
        }
        if let leftAt, Date.now.timeIntervalSince(leftAt) >= Double(delay.rawValue) {
            isLocked = true
        }
        leftAt = nil
        promptPending = isLocked
    }

    /// For a window that shows without activating the app, such as the
    /// quick composer (#307): locks once the delay is over, as a return
    /// would. `leftAt` and the prompt stay for the next activation.
    func checkWithoutActivation() {
        guard isEnabled else { return }
        if let leftAt, Date.now.timeIntervalSince(leftAt) >= Double(delay.rawValue) {
            isLocked = true
        }
    }

    /// Turning the setting on does not lock the running app, only the next
    /// return. Turning it off goes through `confirmOwner` first.
    func settingChanged() {
        isEnabled = defaults.bool(forKey: Self.enabledKey) && !DemoMode.isOn
        if !isEnabled { isLocked = false }
    }

    /// Asks for Face ID, Touch ID or the passcode, e.g. before the lock is
    /// turned off; true when the owner confirmed.
    func confirmOwner() async -> Bool {
        let context = LAContext()
        let reason = String(localized: "App-Sperre ausschalten")
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
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
