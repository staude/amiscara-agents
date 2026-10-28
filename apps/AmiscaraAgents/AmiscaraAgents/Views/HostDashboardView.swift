import SwiftUI

#if !os(tvOS)
/// One host in the widget's look (#278): the waiting count large, the
/// working ones below, a row per agent and how current it is. While the
/// host reconnects its last agents stay; without a connection the Mac's
/// board in iCloud stands in, as in the widget. A tap opens the agent.
struct HostDashboardView: View {
    @Environment(HostStore.self) private var store
    let connection: HostConnection
    let open: (SpaceRef) -> Void

    var body: some View {
        let local = localSnapshot
        let snapshot = local.merging(store.cloudBoards)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    WaitingHeadline(waiting: snapshot.count(.blocked), working: snapshot.count(.working))
                }
                .padding(.bottom, 8)
                if snapshot.agents.isEmpty {
                    Text("Keine Agents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.agents, id: \.agent.id) { _, agent in
                        Button {
                            open(SpaceRef(hostID: connection.id, workspaceID: agent.workspaceID, paneID: agent.paneID))
                        } label: {
                            AgentSummaryRow(agent: agent, host: nil)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                footer(local: local, shown: snapshot)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(connection.config.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var hostKey: String? {
        CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
    }

    /// What this device knows: the live board, else the last one it saw
    /// while live, dated when the host was last connected.
    private var localSnapshot: WidgetSnapshot {
        let live = connection.isLive
        let board = live ? connection.update?.board ?? [] : connection.lastBoard
        return WidgetSnapshot(updated: live ? .now : connection.liveAt ?? .distantPast, hosts: [
            WidgetSnapshot.Host(
                id: connection.id,
                name: connection.config.name,
                live: live,
                agents: board.map(WidgetSnapshot.Agent.init),
                hostKey: hostKey
            ),
        ])
    }

    /// "Live" while connected; otherwise the age of the shown agents, from
    /// the Mac's board when that stood in. Updates come only on changes, so
    /// a connected host gets no age.
    @ViewBuilder
    private func footer(local: WidgetSnapshot, shown: WidgetSnapshot) -> some View {
        Group {
            if connection.isLive {
                Text("Live")
            } else if shown.hosts != local.hosts {
                let board = store.cloudBoards.filter { $0.hostKey == hostKey }.max { $0.updated < $1.updated }
                Text("Stand \(board?.updated ?? shown.updated, style: .relative) · über iCloud")
            } else if local.updated == .distantPast {
                Text("Keine Daten")
            } else {
                Text("Stand \(local.updated, style: .relative)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}
#endif
