import SwiftUI

/// What the sidebar selects: a space, optionally with one of its panes
/// (when an agent was picked).
struct SpaceRef: Hashable, Sendable {
    let hostID: UUID
    let workspaceID: String
    var paneID: String?
}

/// The sidebar, laid out like herdr's own: per host the spaces (linked
/// worktrees indented under their repository's space), then the agents as
/// "space · tab" with the agent below, waiting ones first.
struct HostSidebar: View {
    @Environment(HostStore.self) private var store
    @Binding var selection: SpaceRef?
    @Binding var editing: HostConfig?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.connections) { connection in
                Section {
                    if let update = connection.update {
                        hostContent(connection, update)
                    }
                } header: {
                    HostHeader(connection: connection)
                        .contextMenu {
                            Button("Bearbeiten …") { editing = connection.config }
                            Button("Neu verbinden") { connection.start() }
                            Divider()
                            Button("Entfernen", role: .destructive) {
                                store.remove(connection.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Herdr Remote")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AddHostButton(editing: $editing)
            }
        }
        .overlay {
            if store.connections.isEmpty {
                NoHostsView(editing: $editing)
            }
        }
    }

    @ViewBuilder
    private func hostContent(_ connection: HostConnection, _ update: SessionUpdate) -> some View {
        SubHeader(title: String(localized: "Spaces"))
        ForEach(SpaceOrder.arrange(update.workspaces), id: \.workspace.workspaceId) { entry in
            SpaceRow(workspace: entry.workspace, nested: entry.nested)
                .tag(SpaceRef(hostID: connection.id, workspaceID: entry.workspace.workspaceId))
        }
        if !update.board.isEmpty {
            SubHeader(title: String(localized: "Agents"))
            ForEach(update.board, id: \.paneId) { agent in
                AgentRow(agent: agent)
                    .tag(SpaceRef(hostID: connection.id, workspaceID: agent.workspaceId, paneID: agent.paneId))
            }
        }
    }
}

/// herdr's order: spaces by number, each linked worktree right after the
/// first space of the same repository.
enum SpaceOrder {
    struct Entry {
        let workspace: WorkspaceItem
        let nested: Bool
    }

    static func arrange(_ workspaces: [WorkspaceItem]) -> [Entry] {
        let sorted = workspaces.sorted { $0.number < $1.number }
        let worktrees = sorted.filter { $0.worktreeName != nil }
        var placed = Set<String>()
        var result: [Entry] = []
        for workspace in sorted where workspace.worktreeName == nil {
            result.append(Entry(workspace: workspace, nested: false))
            guard let repo = workspace.repoKey else { continue }
            for worktree in worktrees where worktree.repoKey == repo && !placed.contains(worktree.workspaceId) {
                result.append(Entry(workspace: worktree, nested: true))
                placed.insert(worktree.workspaceId)
            }
        }
        // Worktrees whose main checkout has no space of its own.
        for worktree in worktrees where !placed.contains(worktree.workspaceId) {
            result.append(Entry(workspace: worktree, nested: false))
        }
        return result
    }
}

private struct SubHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.lowercase)
            .padding(.top, 4)
    }
}

private struct SpaceRow: View {
    let workspace: WorkspaceItem
    let nested: Bool

    var body: some View {
        HStack(spacing: 6) {
            if nested {
                Text("└")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
            }
            StatusDot(state: workspace.agentState)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.worktreeName ?? workspace.label)
                    .lineLimit(1)
                if workspace.worktreeName != nil && !nested {
                    Text(workspace.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AgentRow: View {
    let agent: BoardItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusDot(state: agent.agentState)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(agent.workspaceLabel) · \(agent.tabLabel)")
                        .lineLimit(1)
                    if agent.agentState != .idle {
                        Text(agent.agentState.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(agent.agentState.color)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        agent.title.isEmpty || agent.title == agent.agent ? agent.agent : "\(agent.agent) · \(agent.title)"
    }
}

private struct HostHeader: View {
    let connection: HostConnection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.config.kind == .local ? "desktopcomputer" : "network")
            Text(connection.config.name)
            Spacer()
            HostStatusLabel(connection: connection)
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
