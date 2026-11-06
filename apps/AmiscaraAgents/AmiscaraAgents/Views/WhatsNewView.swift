#if os(macOS)
import SwiftUI

/// What the "Neuigkeiten" window lists (#341): after an update the new
/// versions, from the Help menu all up to the installed one.
@Observable @MainActor
final class WhatsNewState {
    static let shared = WhatsNewState()

    var entries: [WhatsNewEntry]

    private init() {
        entries = WhatsNew.history(WhatsNew.bundled(), current: WhatsNew.currentVersion)
    }

    /// For "Hilfe › Neuigkeiten".
    func showHistory() {
        entries = WhatsNew.history(WhatsNew.bundled(), current: WhatsNew.currentVersion)
    }

    /// On start: true when an update brought notes to show once.
    func takeUpdateNotes() -> Bool {
        let pending = WhatsNew.onLaunch(WhatsNew.bundled(), current: WhatsNew.currentVersion)
        guard !pending.isEmpty else { return false }
        entries = pending
        return true
    }
}

enum WhatsNewWindow {
    nonisolated static let id = "whats-new"
}

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
        .frame(minWidth: 380, idealWidth: 440, minHeight: 240, idealHeight: 360)
    }
}

/// Opens the window once after an update; not in the screenshot demo.
private struct WhatsNewAfterUpdate: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard !DemoMode.isOn else { return }
            if WhatsNewState.shared.takeUpdateNotes() {
                openWindow(id: WhatsNewWindow.id)
            }
        }
    }
}

extension View {
    func whatsNewAfterUpdate() -> some View {
        modifier(WhatsNewAfterUpdate())
    }
}
#endif
