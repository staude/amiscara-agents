import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if !os(tvOS)
extension View {
    /// Covers the app while the app lock (#232) holds, and on iOS also while
    /// the app is not active, so the app switcher shows no panes. The cover
    /// is a window of its own above sheets and alerts; on the Mac the app's
    /// windows are hidden until it is unlocked.
    func appLock() -> some View {
        modifier(AppLockModifier())
    }
}

private struct AppLockModifier: ViewModifier {
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    private var covered: Bool {
        guard lock.isEnabled else { return false }
        #if os(iOS)
        return lock.isLocked || scenePhase != .active
        #else
        return lock.isLocked
        #endif
    }

    func body(content: Content) -> some View {
        content
            // Nothing behind the cover takes focus, keys or menu commands.
            .disabled(covered)
            .accessibilityHidden(covered)
            .onChange(of: covered, initial: true) { _, covered in
                AppLockCurtain.shared.show(covered, lock: lock)
            }
            #if os(iOS)
            // Not .inactive: Face ID itself and Control Center make the
            // scene inactive without leaving the app.
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .background: lock.didLeave()
                case .active: lock.didReturn()
                default: break
                }
            }
            #elseif os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                lock.didLeave()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                lock.didReturn()
            }
            .onAppear { lock.didReturn() }
            #endif
    }
}

/// The cover as a window above everything the app shows.
@MainActor
final class AppLockCurtain {
    static let shared = AppLockCurtain()

    #if os(iOS)
    private var windows: [UIWindow] = []

    func show(_ covered: Bool, lock: AppLock) {
        guard covered else {
            windows.forEach { $0.isHidden = true }
            windows = []
            return
        }
        guard windows.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: AppLockCover(lock: lock))
            window.isHidden = false
            windows.append(window)
        }
    }
    #elseif os(macOS)
    private var window: NSWindow?
    private var hidden: [NSWindow] = []

    var isShowing: Bool { window != nil }

    func show(_ covered: Bool, lock: AppLock) {
        guard covered else {
            window?.orderOut(nil)
            window = nil
            hidden.forEach { $0.orderFront(nil) }
            hidden.first?.makeKey()
            hidden = []
            return
        }
        guard window == nil else { return }
        // The main window, its sheets and the settings; not the menu bar
        // item's windows, which cannot become main.
        hidden = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        hidden.forEach { $0.orderOut(nil) }
        let cover = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        cover.title = "Amiscara Agents"
        cover.isReleasedWhenClosed = false
        cover.contentView = NSHostingView(rootView: AppLockCover(lock: lock))
        cover.center()
        cover.makeKeyAndOrderFront(nil)
        window = cover
    }

    /// Fronts the cover instead of a hidden window, e.g. for the menu bar.
    @discardableResult
    func bringToFront() -> Bool {
        guard let window else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }
    #endif
}

private struct AppLockCover: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Amiscara Agents ist gesperrt")
                    .font(.headline)
                if lock.isLocked {
                    Button("Entsperren", systemImage: "faceid") { lock.unlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(lock.isAuthenticating)
                }
                if let failure = lock.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }
}

/// The lock's settings: on/off and when it applies again. Turning it off
/// asks for the owner first.
struct AppLockSettings: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.delayKey) private var delay = AppLock.Delay.immediately.rawValue

    var body: some View {
        Toggle("App sperren", isOn: Binding(
            get: { enabled },
            set: { on in
                if on {
                    enabled = true
                    AppLock.shared.settingChanged()
                } else {
                    Task {
                        guard await AppLock.shared.confirmOwner() else { return }
                        enabled = false
                        AppLock.shared.settingChanged()
                    }
                }
            }
        ))
        .disabled(!enabled && !AppLock.isAvailable)
        if enabled {
            Picker("Sperren", selection: $delay) {
                ForEach(AppLock.Delay.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
        }
    }
}
#endif
