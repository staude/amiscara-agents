import SwiftUI

/// Which agent to start in a new space, tab or worktree: none, or one of
/// the kinds the host's herdr can start. herdr types the agent's command
/// into the new shell, so the agent must be installed on the host.
struct AgentPicker: View {
    let connection: HostConnection
    @Binding var kind: String?
    @State private var kinds: [String] = []

    var body: some View {
        Picker("Agent starten", selection: $kind) {
            Text("Keinen, nur Shell").tag(String?.none)
            ForEach(options, id: \.self) { kind in
                Text(kind).tag(Optional(kind))
            }
        }
        .task { kinds = await connection.agentKinds() }
    }

    /// The remembered choice stays selectable before the list has arrived.
    private var options: [String] {
        guard let kind, !kinds.contains(kind) else { return kinds }
        return [kind] + kinds
    }
}
