import SwiftUI

#if !os(tvOS)
/// The agents of all hosts in one list (#274): waiting, working, done,
/// newest first in each group. A tap opens the agent's pane.
struct OverviewView: View {
    @Environment(HostStore.self) private var store
    let open: (SpaceRef) -> Void

    /// The plan whose overview is shown (#296).
    @State private var approval: Approvals.Item?

    var body: some View {
        let overview = store.overview
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
                List {
                    ApprovalsSection(hostID: nil) { approval = $0 }
                    ForEach(overview.sections) { section in
                        Section(section.group.title) {
                            ForEach(section.rows) { row in
                                Button {
                                    open(SpaceRef(hostID: row.hostID, workspaceID: row.agent.workspaceID, paneID: row.agent.paneID))
                                } label: {
                                    OverviewRow(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .refreshable { await store.approvals.load(store.connections, force: true) }
            }
        }
        .navigationTitle("Übersicht")
        .approvals(store, selected: $approval, open: open)
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
