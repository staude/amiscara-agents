import SwiftUI

#if !os(tvOS)
/// One host in the widget's look (#278): the waiting count large, the
/// working ones below, a row per agent and how current it is. While the
/// host reconnects its last agents stay; without a connection the Mac's
/// board in iCloud stands in by the overview's rule (#274). A tap opens
/// the agent. Below the headline and each Claude agent today's tokens
/// (#302), with the 30 days a tap away.
struct HostDashboardView: View {
    @Environment(HostStore.self) private var store
    let connection: HostConnection
    let open: (SpaceRef) -> Void
    /// The plan whose overview is shown (#296).
    @State private var approval: Approvals.Item?
    @State private var showingUsage = false

    var body: some View {
        let shown = Shown(connection, boards: store.cloudBoards)
        let snapshot = WidgetSnapshot(updated: shown.updated ?? .distantPast, hosts: [
            WidgetSnapshot.Host(id: connection.id, name: connection.config.name, live: connection.isLive, agents: shown.agents),
        ])
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    WaitingHeadline(waiting: snapshot.count(.blocked), working: snapshot.count(.working))
                    usageLine
                        .padding(.top, 4)
                }
                .padding(.bottom, 8)
                ApprovalsSection(hostID: connection.id) { approval = $0 }
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
                            VStack(alignment: .leading, spacing: 2) {
                                AgentSummaryRow(agent: agent, host: nil)
                                if let cwd = claudeFolders[agent.paneID],
                                   let usage = connection.usage.todaySum(cwd: cwd, prices: .shared) {
                                    Text(usage.todayText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                footer(shown)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .refreshable { await store.approvals.load(store.connections, force: true) }
        .navigationTitle(connection.config.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .approvals(store, selected: $approval, open: open)
        .onAppear { connection.usage.visible += 1 }
        .onDisappear { connection.usage.visible -= 1 }
        // Again when the host comes back or an agent opens elsewhere.
        .task(id: [connection.isLive ? "live" : ""] + UsageStore.claudeFolders(connection.update?.board ?? [])) {
            await connection.usage.refreshToday()
        }
        .sheet(isPresented: $showingUsage) {
            UsageDetailView(connection: connection)
        }
    }

    /// The working directory of each Claude agent, by pane.
    private var claudeFolders: [String: String] {
        Dictionary(connection.lastBoard.compactMap { item in
            item.agent == "claude" ? item.cwd.map { (item.paneId, $0) } : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    /// "Heute: n Tokens, ~$x" over the open Claude agents, a tap to the 30
    /// days; or why there is nothing.
    @ViewBuilder
    private var usageLine: some View {
        let usage = connection.usage
        Group {
            if usage.phase == .filesOff {
                Text("Tokens und Kosten brauchen Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
            } else if let today = usage.todaySum(prices: .shared) {
                Button {
                    showingUsage = true
                } label: {
                    Label(today.todayText, systemImage: "chart.bar.xaxis")
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Tokens und Kosten der letzten 30 Tage"))
            } else if case .failed(let message) = usage.phase {
                Text("Tokens nicht lesbar: \(message)")
            } else if usage.phase == .loading {
                Text("Tokens werden gelesen …")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The agents shown, how old they are and whether they came from
    /// iCloud; also the sidebar's badge counts from here.
    struct Shown {
        let agents: [WidgetSnapshot.Agent]
        let updated: Date?
        let fromCloud: Bool

        /// The live board; without a connection the newer of the last
        /// board seen here and the Mac's board in iCloud, by the overview's
        /// rule. Its own boards also come back to a Mac from iCloud, a few
        /// minutes late; the rule keeps them from replacing newer agents.
        @MainActor
        init(_ connection: HostConnection, boards: [CloudBoard]) {
            if connection.isLive {
                agents = (connection.update?.board ?? []).map(WidgetSnapshot.Agent.init)
                updated = nil
                fromCloud = false
                return
            }
            let key = CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
            if let board = AgentOverview.newestBoard(for: key, in: boards),
               AgentOverview.standsIn(board, liveAt: connection.liveAt) {
                agents = board.agents
                updated = board.updated
                fromCloud = true
            } else {
                agents = connection.lastBoard.map(WidgetSnapshot.Agent.init)
                updated = connection.liveAt
                fromCloud = false
            }
        }

        var waiting: Int { agents.filter { $0.state == .blocked }.count }
    }

    /// "Live" while connected; otherwise the age of the shown agents.
    /// Updates come only on changes, so a connected host gets no age.
    private func footer(_ shown: Shown) -> some View {
        Group {
            if connection.isLive {
                Text("Live")
            } else if let updated = shown.updated {
                if shown.fromCloud {
                    Text("Stand \(updated, style: .relative) · über iCloud")
                } else {
                    Text("Stand \(updated, style: .relative)")
                }
            } else {
                Text("Keine Daten")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}
#endif
