import AppIntents
import SwiftUI

@main
struct AmiscaraAgentsApp: App {
    @State private var store: HostStore
    #if os(iOS)
    /// Remote notifications for the iCloud subscriptions (#119).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    /// Remote notifications for the Watch's commands (#160).
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    init() {
        let store = HostStore()
        _store = State(initialValue: store)
        #if !os(tvOS)
        // Shortcuts and Siri run in this process and read the same store.
        AppDependencyManager.shared.add(dependency: store)
        #endif
    }

    var body: some Scene {
        // The id lets the menu bar item open a window (MainWindow.id).
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .appAppearance(appearance)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        #if !os(tvOS)
        .commands { AppCommands() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app and the SSH session with it. Coming back,
            // reconnect at once instead of waiting out the retry pause.
            store.notifier.appActive = phase == .active
            // The screenshot demo (#199) leaves widgets and iCloud alone.
            guard !DemoMode.isOn else { return }
            if phase == .active {
                store.reconnectStale()
                #if os(iOS)
                Task { await CloudPushSubscriptions.shared.install() }
                #endif
                #if !os(macOS)
                Task { await store.widgets.refreshFromCloud(store) }
                #endif
            } else if phase == .background {
                // The widgets keep showing this state until the app runs again.
                store.widgets.publish(store, force: true)
            }
        }
        #if !os(tvOS)
        .commands { TerminalZoomCommands() }
        #endif
        #if os(macOS)
        .commands { UpdateCommands() }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
        }
        // Owned by the app like the store, so hosts stay connected and
        // notifications keep coming while the window is closed.
        MenuBarExtra {
            MenuBarMenu(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        #endif
    }
}

/// A pane on a specific host, the unit of selection.
struct PaneRef: Hashable, Sendable {
    let hostID: UUID
    let paneID: String
}
