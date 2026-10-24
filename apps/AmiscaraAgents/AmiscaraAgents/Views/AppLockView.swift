import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if !os(tvOS)
extension View {
    /// Covers the window while the app lock (#232) holds, and on iOS also
    /// while the app is not active, so the app switcher shows no panes. The
    /// cover is also a window of its own above sheets and alerts; on the Mac
    /// the app's windows are hidden until it is unlocked.
    func appLock() -> some View {
        modifier(AppLockModifier())
    }
}

private struct AppLockModifier: ViewModifier {
    @State private var lock = AppLock.shared

    func body(content: Content) -> some View {
        let covered = lock.isCovered
        content
            // Nothing behind the cover takes focus, keys or menu commands.
            .disabled(covered)
            .accessibilityHidden(covered)
            // Each window covers itself too, also one opened while locked.
            .overlay {
                if covered {
                    AppLockCover(lock: lock)
                }
            }
            .onChange(of: covered, initial: true) { _, covered in
                AppLockCurtain.shared.show(covered, lock: lock)
            }
            .onAppear {
                if covered { AppLockCurtain.shared.show(true, lock: lock) }
            }
    }
}

/// The cover as a window above everything the app shows.
@MainActor
final class AppLockCurtain {
    static let shared = AppLockCurtain()

    #if os(iOS)
    private var windows: [UIWindow] = []
    /// The windows that were key before, to give the keyboard back.
    private var keyWindows: [UIWindow] = []

    /// Covers every scene that has no cover yet, so a scene connected while
    /// locked gets one as well. The cover becomes the key window, so
    /// keyboard shortcuts do not reach the panes behind it.
    func show(_ covered: Bool, lock: AppLock) {
        guard covered else {
            windows.forEach { $0.isHidden = true }
            windows = []
            keyWindows.forEach { $0.makeKey() }
            keyWindows = []
            return
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        where !windows.contains(where: { $0.windowScene === scene }) {
            if let key = scene.keyWindow { keyWindows.append(key) }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: AppLockCover(lock: lock))
            window.makeKeyAndVisible()
            windows.append(window)
        }
    }
    #elseif os(macOS)
    private var window: NSWindow?
    private var hidden: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    /// Hides the app's windows behind a lock window; runs again whenever a
    /// window comes up while locked (File › New Window, the Dock).
    func show(_ covered: Bool, lock: AppLock) {
        guard covered else {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            window?.orderOut(nil)
            window = nil
            hidden.forEach { $0.orderFront(nil) }
            hidden.first?.makeKey()
            hidden = []
            return
        }
        // The main window, its sheets and the settings, minimized ones too;
        // not the menu bar item's windows, which cannot become main.
        let shown = NSApp.windows.filter {
            $0 !== window && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
        shown.forEach { $0.orderOut(nil) }
        hidden += shown.filter { !hidden.contains($0) }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
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
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let other = ObjectIdentifier(note.object as AnyObject)
                MainActor.assumeIsolated {
                    guard let self, let cover = self.window, other != ObjectIdentifier(cover) else { return }
                    self.show(true, lock: lock)
                }
            })
        }
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
