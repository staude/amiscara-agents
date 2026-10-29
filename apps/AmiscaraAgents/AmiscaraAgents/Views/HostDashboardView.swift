import SwiftUI

#if !os(tvOS)
/// One host in the widget's look (#278): the waiting count large, the
/// working ones below, a row per agent and how current it is. While the
/// host reconnects its last agents stay; without a connection the Mac's
/// board in iCloud stands in by the overview's rule (#274). A tap opens
/// the agent. Below the headline and each Claude agent today's tokens
/// (#302), with the 30 days a tap away. The search field searches all
/// Claude conversations of the host (#303); its results replace the agents
/// until the field is empty.
struct HostDashboardView: View {
    @Environment(HostStore.self) private var store
    let connection: HostConnection
    let open: (SpaceRef) -> Void
    /// The plan whose overview is shown (#296).
    @State private var approval: Approvals.Item?
    @State private var searchText = ""
    @State private var search = ConversationSearch()
    /// The hit whose conversation is open.
    @State private var opened: OpenedHit?

    private struct OpenedHit: Identifiable {
        let sessionPath: String
        let offset: UInt64
        var id: String { "\(sessionPath)#\(offset)" }
    }

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
                if search.started, !searchText.isEmpty {
                    SearchResults(search: search, connection: connection) { hit in
                        opened = OpenedHit(sessionPath: hit.sessionPath, offset: hit.offset)
                    }
                } else if snapshot.agents.isEmpty {
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
        .searchable(text: $searchText, prompt: Text("Gespräche durchsuchen"))
        // Each search scans the host's files, so only on Return.
        .onSubmit(of: .search) {
            search.start(searchText, on: connection)
        }
        .onChange(of: searchText) {
            if searchText.isEmpty { search.clear() }
        }
        .onChange(of: connection.id) {
            searchText = ""
            search.clear()
        }
        .onDisappear { search.cancel() }
        .sheet(item: $opened) { hit in
            ConversationView(connection: connection, source: .match(sessionPath: hit.sessionPath, offset: hit.offset))
        }
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

/// The hits of a conversation search by space and session, with its
/// progress and how it ended.
private struct SearchResults: View {
    let search: ConversationSearch
    let connection: HostConnection
    let open: (ConversationHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if search.running {
                HStack(spacing: 10) {
                    if let progress = search.progress, progress.total > 0 {
                        ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Abbrechen") { search.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("Durchsucht die Gespräche auf dem Host …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            notes
            ForEach(search.groups) { space in
                VStack(alignment: .leading, spacing: 6) {
                    spaceHeader(space)
                    ForEach(space.sessions) { session in
                        sessionHeader(session)
                        ForEach(session.hits) { found in
                            Button { open(found.hit) } label: {
                                HitRow(found: found, query: search.query)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        Group {
            if let error = search.error {
                Label(error, systemImage: "exclamationmark.triangle")
            } else if let end = search.end {
                if end.cancelled {
                    Text("Suche abgebrochen.")
                } else if search.hits.isEmpty {
                    Text("Keine Treffer für „\(search.query)“.")
                }
                if end.truncated {
                    Text("Mehr Treffer, als die Suche zeigt. Ein genaueres Suchwort hilft.")
                }
                if end.olderSkipped {
                    Text("Nur die Gespräche der letzten 30 Tage durchsucht; ältere fehlen. Auf dem Host selbst sucht die App, wenn Eingaben erlaubt sind und ein Space offen ist.")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func spaceHeader(_ space: ConversationSearch.SpaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let id = space.workspaceID,
               let label = connection.update?.workspaces.first(where: { $0.workspaceId == id })?.label {
                Text(label)
            } else {
                Text("Ohne Space")
                if let cwd = space.cwd {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .font(.headline)
    }

    private func sessionHeader(_ session: ConversationSearch.SessionGroup) -> some View {
        Group {
            if let title = session.title, !title.isEmpty {
                Text(title)
            } else if let date = session.newest {
                Text("Sitzung vom \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Sitzung")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.top, 2)
    }
}

/// A hit: who wrote it, the text around the match with the search word in
/// bold, and when.
private struct HitRow: View {
    let found: ConversationSearch.Found
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet)
                    .font(.callout)
                    .lineLimit(3)
                if let date = found.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch found.hit.kind {
        case .user: "person"
        case .assistant: "sparkles"
        case .tool: "wrench.and.screwdriver"
        }
    }

    private var snippet: AttributedString {
        var text = AttributedString(found.hit.snippet)
        guard !query.isEmpty else { return text }
        var rest = text.startIndex..<text.endIndex
        while let match = text[rest].range(of: query, options: .caseInsensitive) {
            text[match].inlinePresentationIntent = .stronglyEmphasized
            rest = match.upperBound..<text.endIndex
        }
        return text
    }
}
#endif
