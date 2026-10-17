import SwiftUI

@main
struct HerdrRemoteApp: App {
    @State private var store = HostStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 600)
        }
    }
}

/// A pane on a specific host, the unit of selection.
struct PaneRef: Hashable, Sendable {
    let hostID: UUID
    let paneID: String
}
