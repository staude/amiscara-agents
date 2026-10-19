import SwiftUI

/// All agents over all hosts, waiting first, as on the iPhone's board.
struct AgentListView: View {
    @Environment(WatchStore.self) private var store
    @State private var path: [AgentRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.snapshot.hosts.isEmpty {
                    Text("Noch keine Hosts. Öffne Amiscara Agents auf dem iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if store.snapshot.agents.isEmpty {
                    Text("Keine Agents.")
                        .foregroundStyle(.secondary)
                } else {
                    // Pane ids repeat across hosts; host and pane together do not.
                    ForEach(store.snapshot.refs, id: \.ref) { entry in
                        NavigationLink(value: entry.ref) {
                            AgentRow(host: entry.host, agent: entry.agent, showHost: store.snapshot.hosts.count > 1)
                        }
                    }
                }
                if store.snapshot.updated != .distantPast {
                    Text("Stand \(store.snapshot.updated, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Agents")
            .navigationDestination(for: AgentRef.self) { ref in
                AgentDetailView(ref: ref)
            }
            .refreshable { await store.refresh() }
            .onChange(of: store.openRequest) { _, ref in
                guard let ref else { return }
                store.openRequest = nil
                path = [ref]
            }
        }
    }
}

struct AgentRow: View {
    let host: WidgetSnapshot.Host
    let agent: WidgetSnapshot.Agent
    let showHost: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agent.state.color)
                .frame(width: 8, height: 8)
                .accessibilityLabel(agent.state.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(showHost ? "\(host.name) · \(agent.place)" : agent.place)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
