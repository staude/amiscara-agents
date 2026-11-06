#if !os(tvOS)
import SwiftUI

/// The overview as a board (#345): a column per state with a card per
/// agent, across all hosts. Plans waiting for approval get a column of their
/// own while there are any, so they do not wait unseen. A tap on a card does
/// what a tap on a row of the list does; in the selection mode it picks the
/// agent for one prompt to several.
struct OverviewBoard<CardMenu: View>: View {
    @Environment(HostStore.self) private var store
    let overview: AgentOverview
    let targets: [MultiSend.Target]
    let selecting: Bool
    @Binding var selected: Set<String>
    let tap: (AgentOverview.Row) -> Void
    let selectApproval: (Approvals.Item) -> Void
    @ViewBuilder let menu: (AgentOverview.Row) -> CardMenu

    @State private var excerpts = BoardExcerpts()

    var body: some View {
        let board = AgentBoard(overview)
        let hasApprovals = !store.approvals.items(for: nil, in: store.connections).isEmpty
            || !store.approvals.errors(for: nil, in: store.connections).isEmpty
        HStack(alignment: .top, spacing: 12) {
            if hasApprovals {
                List {
                    ApprovalsSection(hostID: nil, select: selectApproval)
                }
                .frame(width: 260)
            }
            ForEach(board.columns) { column in
                columnView(column)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .task(id: overview) {
            let rows = board.columns.flatMap(\.rows)
            await excerpts.refresh(rows, store: store)
            // Working agents say more by the minute; the rest stays as read.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BoardRead.refresh))
                if Task.isCancelled { return }
                await excerpts.refresh(rows, store: store)
            }
        }
    }

    private func columnView(_ column: AgentBoard.Column) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.group.title)
                    .font(.headline)
                Text("\(column.rows.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if column.rows.isEmpty {
                        Text("Keine")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    ForEach(column.rows) { row in
                        let target = targets.first { $0.id == row.id }
                        Button {
                            if selecting {
                                if let target { MultiSend.toggle(target, in: &selected) }
                            } else {
                                tap(row)
                            }
                        } label: {
                            if selecting, let target {
                                MultiSendRow(target: target, selected: selected.contains(target.id)) {
                                    BoardCard(row: row, lines: excerpts.lines[row.id] ?? [])
                                }
                            } else {
                                BoardCard(row: row, lines: excerpts.lines[row.id] ?? [])
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu(when: !selecting) { menu(row) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct BoardCard: View {
    let row: AgentOverview.Row
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(row.agent.state.color)
                    .frame(width: 8, height: 8)
                if row.pinned {
                    PinMark()
                }
                Text(row.agent.place)
                    .lineLimit(1)
            }
            Text([row.agent.name, row.hostName].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            OverviewAge(row: row)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .lineLimit(1)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
#endif
