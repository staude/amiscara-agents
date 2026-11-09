#if os(macOS) || os(iOS)
import SwiftUI

/// What the "Neuigkeiten" window (Mac) or sheet (iPhone, iPad) lists (#341,
/// #382): after an update the new versions, from the Help menu or the
/// sidebar's menu all up to the installed one.
@Observable @MainActor
final class WhatsNewState {
    static let shared = WhatsNewState()

    var entries: [WhatsNewEntry]
    #if os(iOS)
    /// Whether the sheet is up.
    var isPresented = false
    #endif

    private init() {
        entries = WhatsNew.history(WhatsNew.bundled(), current: WhatsNew.currentVersion)
    }

    /// For "Hilfe › Neuigkeiten" and the sidebar's menu.
    func showHistory() {
        entries = WhatsNew.history(WhatsNew.bundled(), current: WhatsNew.currentVersion)
        #if os(iOS)
        isPresented = true
        #endif
    }

    /// On start: true when an update brought notes to show once.
    func takeUpdateNotes(earlierInstall: Bool) -> Bool {
        let pending = WhatsNew.onLaunch(
            WhatsNew.bundled(), current: WhatsNew.currentVersion, earlierInstall: earlierInstall
        )
        guard !pending.isEmpty else { return false }
        entries = pending
        #if os(iOS)
        isPresented = true
        #endif
        return true
    }
}

#if os(macOS)
enum WhatsNewWindow {
    nonisolated static let id = "whats-new"
}
#endif

/// The window's content: per version its points.
struct WhatsNewView: View {
    @State private var state = WhatsNewState.shared
    private let german = WhatsNew.prefersGerman

    var body: some View {
        Group {
            if state.entries.isEmpty {
                ContentUnavailableView("Keine Neuigkeiten für diese Version", systemImage: "sparkles")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(state.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Version \(entry.version)")
                                    .font(.headline)
                                ForEach(Array(entry.notes(german: german).enumerated()), id: \.offset) { _, note in
                                    Label {
                                        Text(note)
                                    } icon: {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .labelStyle(.titleAndIcon)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 240, idealHeight: 360)
        #endif
    }
}

#if os(macOS)
/// Opens the window once after an update; not in the screenshot demo.
private struct WhatsNewAfterUpdate: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(HostStore.self) private var store

    func body(content: Content) -> some View {
        content.task {
            guard !DemoMode.isOn else { return }
            if WhatsNewState.shared.takeUpdateNotes(earlierInstall: store.hadSavedHosts) {
                openWindow(id: WhatsNewWindow.id)
            }
        }
    }
}
#else
/// Shows the sheet once after an update, and from the sidebar's menu later;
/// not in the screenshot demo. A second iPad window shows nothing on start
/// because the first one already noted the version.
private struct WhatsNewAfterUpdate: ViewModifier {
    @Environment(HostStore.self) private var store
    @State private var state = WhatsNewState.shared

    func body(content: Content) -> some View {
        content
            .task {
                guard !DemoMode.isOn else { return }
                _ = state.takeUpdateNotes(earlierInstall: store.hadSavedHosts)
            }
            .sheet(isPresented: $state.isPresented) {
                NavigationStack {
                    WhatsNewView()
                        .navigationTitle("Neuigkeiten")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { state.isPresented = false }
                            }
                        }
                }
            }
    }
}
#endif

extension View {
    func whatsNewAfterUpdate() -> some View {
        modifier(WhatsNewAfterUpdate())
    }
}
#endif
