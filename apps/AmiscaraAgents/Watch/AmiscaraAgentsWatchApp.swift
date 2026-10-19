import SwiftUI

/// Amiscara Agents on the Apple Watch (#157): who waits, what is asked, and
/// a tap to answer. No terminal, no host settings; that stays on the
/// iPhone.
@main
struct AmiscaraAgentsWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AgentListView()
                .environment(store)
                .tint(.amiscaraAccent)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await store.refresh() }
            }
        }
    }
}

extension Color {
    /// The app's accent in dark mode, which the Watch always uses.
    static let amiscaraAccent = Color(red: 0x2F / 255, green: 0xD1 / 255, blue: 0xA5 / 255)
}
