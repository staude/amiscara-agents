import SwiftUI

@main
struct HerdrRemoteApp: App {
    @State private var store = HostStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // The id lets the menu bar item open a window (MainWindow.id).
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app and the SSH session with it. Coming back,
            // reconnect at once instead of waiting out the retry pause.
            store.notifier.appActive = phase == .active
            if phase == .active {
                store.reconnectStale()
            }
        }
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
