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
    #if !os(macOS)
    /// When the app went to the background, to reconnect after a long
    /// pause (#258).
    @State private var backgroundSince: Date?
    #endif

    init() {
        DemoMode.applyHome()
        let store = HostStore()
        _store = State(initialValue: store)
        #if !os(tvOS)
        // The app lock follows the app's activation from the start (#232).
        AppLock.shared.start()
        #endif
        #if !os(tvOS)
        // Shortcuts and Siri run in this process and read the same store.
        AppDependencyManager.shared.add(dependency: store)
        #endif
        #if os(macOS)
        // The Mac app runs on in the background, even without a window; a
        // sleep is what kills the links to remote hosts (#258).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard !DemoMode.isOn else { return }
                store.reconnectRemote()
            }
        }
        #endif
    }

    #if !os(macOS)
    /// How long the app must have been in the background before it
    /// reconnects remote hosts on return.
    private static let reconnectAfterBackground: TimeInterval = 30
    #endif

    var body: some Scene {
        // The id lets the menu bar item open a window (MainWindow.id).
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .appAppearance(appearance)
                #if !os(tvOS)
                .appLock()
                #endif
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
            // The last screens go to disk before the app may be ended (#276).
            if phase != .active { PaneCache.shared.flush() } else { PaneCache.shared.retryMisses() }
            #if os(iOS)
            // Something shared from another app (#225): to its agent.
            // Once: a pane that does not come up must not pull the user back.
            if phase == .active, let share = PendingShare.peek(), !share.opened {
                PendingShare.markOpened()
                store.notifier.openRequest = SpaceRef(hostID: share.hostID, workspaceID: share.workspaceID, paneID: share.paneID)
            }
            #endif
            // The screenshot demo (#199) leaves widgets and iCloud alone.
            guard !DemoMode.isOn else { return }
            if phase == .active {
                #if os(macOS)
                store.reconnectStale()
                #else
                // A long pause leaves remote links dead though they still
                // look live; a short app switch keeps them.
                if let since = backgroundSince, Date.now.timeIntervalSince(since) >= Self.reconnectAfterBackground {
                    store.reconnectRemote()
                } else {
                    store.reconnectStale()
                }
                backgroundSince = nil
                #endif
                #if os(iOS)
                Task { await CloudPushSubscriptions.shared.install() }
                #endif
                #if !os(macOS)
                Task { await store.widgets.refreshFromCloud(store) }
                #endif
            } else if phase == .background {
                #if !os(macOS)
                backgroundSince = .now
                #endif
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
            SettingsView(store: store)
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
