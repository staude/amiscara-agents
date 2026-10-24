import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if !os(tvOS)
extension View {
    /// Covers the content while the app lock (#232) holds, and on iOS also
    /// while the app is not active, so the app switcher shows no panes.
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
            .overlay {
                if covered {
                    AppLockCover(lock: lock)
                }
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

/// The lock's settings: on/off and when it applies again.
struct AppLockSettings: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.delayKey) private var delay = AppLock.Delay.immediately.rawValue

    var body: some View {
        Toggle("App sperren", isOn: $enabled)
            .disabled(!enabled && !AppLock.isAvailable)
            .onChange(of: enabled) { AppLock.shared.settingChanged() }
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
