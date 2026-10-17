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
        WindowGroup {
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
    }
}

/// A pane on a specific host, the unit of selection.
struct PaneRef: Hashable, Sendable {
    let hostID: UUID
    let paneID: String
}
