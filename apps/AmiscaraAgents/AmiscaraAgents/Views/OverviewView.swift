import SwiftUI

#if !os(tvOS)
/// The agents of all hosts in one list or on a board (#274, #345): pinned ones first (#334),
/// then waiting, working, done, newest first in each group. A tap opens the agent's pane; in the
/// selection mode it picks the agent for one prompt to several (#299).
struct OverviewView: View {
    @Environment(HostStore.self) private var store
    let open: (SpaceRef) -> Void

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var sending = false
    /// The plan whose overview is shown (#296).
    @State private var approval: Approvals.Item?
    /// The agent looked into over the list (#332).
    @State private var peeking: AgentPeek?
    /// List or board (#345), remembered.
    @AppStorage(OverviewLayout.storageKey) private var layoutChoice = OverviewLayout.list
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
#endif

    /// The board needs width: not on an iPhone or in a narrow iPad window,
    /// where the list shows without changing the choice.
    private var canBoard: Bool {
#if os(iOS)
        sizeClass != .compact
#else
        true
#endif
    }

    private var layout: OverviewLayout { canBoard ? layoutChoice : .list }

    var body: some View {
        let overview = store.overview
        let targets = targets(overview)
        let approvals = store.approvals.items(for: nil, in: store.connections)
        let approvalErrors = store.approvals.errors(for: nil, in: store.connections)
        Group {
            if overview.isEmpty, approvals.isEmpty, approvalErrors.isEmpty {
                ContentUnavailableView(
                    "Keine Agents",
                    systemImage: "sparkles",
                    description: Text("Kein Agent wartet, arbeitet oder ist fertig.")
                )
            } else {
                switch layout {
                case .list:
                    list(overview, targets)
                case .board:
                    OverviewBoard(
                        overview: overview,
                        targets: targets,
                        selecting: selecting,
                        selected: $selected,
                        tap: tap,
                        selectApproval: { approval = $0 },
                        menu: rowMenu
                    )
                }
            }
        }
        .navigationTitle("Übersicht")
        .approvals(store, selected: $approval, open: open)
        .agentPeek($peeking, open: open)
        .toolbar {
            ToolbarItemGroup {
                if canBoard {
                    Picker("Darstellung", selection: $layoutChoice) {
                        Label("Liste", systemImage: "list.bullet").tag(OverviewLayout.list)
                        Label("Board", systemImage: "rectangle.split.3x1").tag(OverviewLayout.board)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                }
                if selecting {
                    Menu("Auswahl", systemImage: "checklist") {
                        ForEach(MultiSend.Preset.allCases, id: \.self) { preset in
                            Button(preset.title) { selected = MultiSend.select(preset, in: targets) }
                        }
                        Button("Keine") { selected = [] }
                    }
                }
                Button(selecting ? "Fertig" : "Auswählen") {
                    selecting.toggle()
                    selected = []
                }
                // Leaving the selection while sending would stop it.
                .disabled(sending || !selecting && overview.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                MultiSendBar(targets: targets.filter { selected.contains($0.id) }, sending: $sending) {
                    selecting = false
                    selected = []
                }
            }
        }
        // A picked agent that starts waiting or loses its host stays picked,
        // dimmed with the reason, so the result names it; a gone one leaves.
        .onChange(of: targets) { _, targets in
            selected.formIntersection(targets.map(\.id))
        }
    }

    private func list(_ overview: AgentOverview, _ targets: [MultiSend.Target]) -> some View {
        List {
            ApprovalsSection(hostID: nil) { approval = $0 }
            ForEach(overview.sections) { section in
                Section(section.group.title) {
                    ForEach(section.rows) { row in
                        let target = targets.first { $0.id == row.id }
                        Button {
                            if selecting, let target {
                                MultiSend.toggle(target, in: &selected)
                            } else if !selecting {
                                tap(row)
                            }
                        } label: {
                            if selecting, let target {
                                MultiSendRow(target: target, selected: selected.contains(target.id)) {
                                    OverviewRow(row: row)
                                }
                            } else {
                                OverviewRow(row: row)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu(when: !selecting) { rowMenu(row) }
                    }
                }
            }
        }
        .refreshable { await store.approvals.load(store.connections, force: true) }
    }

    /// Opens the agent of a row; ⌥-click peeks instead (#332). List and board.
    private func tap(_ row: AgentOverview.Row) {
        if Platform.optionKeyDown, let peek = peek(row) {
            peeking = peek
        } else {
            open(SpaceRef(hostID: row.hostID, workspaceID: row.agent.workspaceID, paneID: row.agent.paneID))
        }
    }

    /// One menu: a view has only one (#332, #334).
    @ViewBuilder
    private func rowMenu(_ row: AgentOverview.Row) -> some View {
        if let peek = peek(row) {
            PeekMenuItems(peek: peek, open: open) { peeking = $0 }
            Divider()
        }
        if let connection = store.connection(for: row.hostID) {
            PinButton(pinned: row.pinned) {
                AgentPins.shared.toggle(row.agent.paneID, on: connection)
            }
        }
    }

    /// The peek of a row; none for a host without a connection.
    private func peek(_ row: AgentOverview.Row) -> AgentPeek? {
        guard store.connection(for: row.hostID) != nil else { return nil }
        return AgentPeek(hostID: row.hostID, workspaceID: row.agent.workspaceID, paneID: row.agent.paneID)
    }

    /// Every agent of the list as a target; a row from a host without a
    /// connection counts as not live, also when it came from iCloud.
    private func targets(_ overview: AgentOverview) -> [MultiSend.Target] {
        overview.sections.flatMap(\.rows).map { row in
            let connection = store.connection(for: row.hostID)
            return MultiSend.Target(
                hostID: row.hostID,
                hostName: row.hostName,
                agent: row.agent,
                live: row.staleAt == nil && connection?.isLive == true,
                inputAllowed: connection?.config.inputAllowed == true
            )
        }
    }
}

private struct OverviewRow: View {
    let row: AgentOverview.Row

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.agent.state.color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if row.pinned {
                        PinMark()
                    }
                    Text(row.agent.place)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(row.agent.state.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.agent.state.color)
                }
                Text([row.agent.name, row.hostName].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                OverviewAge(row: row)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
#endif

/// Time in the state and, for a host without a connection, the age of the
/// shown state; refreshed every minute.
struct OverviewAge: View {
    let row: AgentOverview.Row

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                if let since = row.since {
                    Text(Self.relative(since, now: context.date))
                }
                if let staleAt = row.staleAt {
                    Label("Stand \(Self.relative(staleAt, now: context.date))", systemImage: "icloud.slash")
                }
            }
        }
    }

    /// "vor 5 Min."; times a little ahead of this device's clock (from
    /// another device) count as now.
    static func relative(_ date: Date, now: Date) -> String {
        min(date, now).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
