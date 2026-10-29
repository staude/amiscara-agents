import SwiftUI

#if !os(tvOS)
/// The agents of all hosts in one list (#274): waiting, working, done,
/// newest first in each group. A tap opens the agent's pane; in the
/// selection mode it picks the agent for one prompt to several (#299).
struct OverviewView: View {
    @Environment(HostStore.self) private var store
    let open: (SpaceRef) -> Void

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var sending = false

    var body: some View {
        let overview = store.overview
        let targets = targets(overview)
        Group {
            if overview.isEmpty {
                ContentUnavailableView(
                    "Keine Agents",
                    systemImage: "sparkles",
                    description: Text("Kein Agent wartet, arbeitet oder ist fertig.")
                )
            } else {
                List {
                    ForEach(overview.sections) { section in
                        Section(section.group.title) {
                            ForEach(section.rows) { row in
                                let target = targets.first { $0.id == row.id }
                                Button {
                                    if selecting, let target {
                                        MultiSend.toggle(target, in: &selected)
                                    } else if !selecting {
                                        open(SpaceRef(hostID: row.hostID, workspaceID: row.agent.workspaceID, paneID: row.agent.paneID))
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
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Übersicht")
        .toolbar {
            ToolbarItemGroup {
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
