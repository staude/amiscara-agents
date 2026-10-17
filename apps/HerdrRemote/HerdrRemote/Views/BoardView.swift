import SwiftUI

/// All agents of all hosts, most urgent first.
struct BoardView: View {
    @Environment(HostStore.self) private var store
    @Binding var selection: PaneRef?
    @Binding var editing: HostConfig?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private struct Entry: Identifiable {
        let host: HostConnection
        let item: BoardItem
        var id: PaneRef { PaneRef(hostID: host.id, paneID: item.paneId) }
    }

    private var entries: [Entry] {
        let all = store.connections.flatMap { host in
            (host.update?.board ?? []).map { Entry(host: host, item: $0) }
        }
        // Each host's board is already sorted; merge by urgency only, so the
        // order within a host stays as the core decided.
        return all.enumerated()
            .sorted { ($0.element.item.agentState.urgency, $0.offset) < ($1.element.item.agentState.urgency, $1.offset) }
            .map(\.element)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                BoardRow(item: entry.item, hostName: store.connections.count > 1 ? entry.host.config.name : nil)
                    .tag(entry.id)
            }
        }
        .navigationTitle("Board")
        .toolbar {
            #if os(iOS)
            // On iPhone the board is the first screen and the sidebar is one
            // step back, so the board offers adding a host as well.
            if sizeClass == .compact {
                ToolbarItem(placement: .primaryAction) {
                    AddHostButton(editing: $editing)
                }
            }
            #endif
        }
        .overlay {
            if store.connections.isEmpty {
                NoHostsView(editing: $editing)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Keine Agents",
                    systemImage: "rectangle.stack",
                    description: Text("Sobald auf einem Host ein Agent läuft, erscheint er hier.")
                )
            }
        }
    }
}

struct NoHostsView: View {
    @Binding var editing: HostConfig?

    var body: some View {
        ContentUnavailableView {
            Label("Keine Hosts", systemImage: "server.rack")
        } description: {
            Text("Fügen Sie einen Rechner hinzu, auf dem herdr läuft.")
        } actions: {
            AddHostButton(editing: $editing)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct BoardRow: View {
    let item: BoardItem
    let hostName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: item.agentState)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title.isEmpty ? item.agent : item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(item.agentState.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.agentState.color)
                }
                Text([hostName, item.workspaceLabel, "Tab \(item.tabLabel)", item.agent]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
