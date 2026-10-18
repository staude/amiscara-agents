import AppIntents
import SwiftUI

@main
struct HerdrRemoteApp: App {
    @State private var store: HostStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = HostStore()
        _store = State(initialValue: store)
        // Shortcuts and Siri run in this process and read the same store.
        AppDependencyManager.shared.add(dependency: store)
    }

    var body: some Scene {
        // The id lets the menu bar item open a window (MainWindow.id).
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        .commands { AppCommands() }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app and the SSH session with it. Coming back,
            // reconnect at once instead of waiting out the retry pause.
            store.notifier.appActive = phase == .active
            if phase == .active {
                store.reconnectStale()
            }
        }
        .commands { TerminalZoomCommands() }
        #if os(macOS)
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
