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
    @State private var newSpaceOn: HostConnection?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.connections) { connection in
                Section {
                    if let update = connection.update {
                        hostContent(connection, update)
                    }
                } header: {
                    HostHeader(connection: connection) {
                        hostActions(connection)
                    }
                    .contextMenu { hostActions(connection) }
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
        .sheet(item: $newSpaceOn) { connection in
            NewSpaceView(connection: connection) { created in
                selection = SpaceRef(hostID: connection.id, workspaceID: created.workspaceId, paneID: created.paneId)
            }
        }
    }

    @ViewBuilder
    private func hostActions(_ connection: HostConnection) -> some View {
        Button("Bearbeiten …", systemImage: "pencil") { editing = connection.config }
        Button("Neu verbinden", systemImage: "arrow.clockwise") { connection.start() }
        Divider()
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            store.remove(connection.id)
        }
    }

    @ViewBuilder
    private func hostContent(_ connection: HostConnection, _ update: SessionUpdate) -> some View {
        HStack {
            SubHeader(title: String(localized: "Spaces"))
            Spacer()
            if connection.config.inputAllowed && connection.isLive {
                Button("Neuer Space", systemImage: "plus") { newSpaceOn = connection }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
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

/// Name and directory for a new space.
private struct NewSpaceView: View {
    let connection: HostConnection
    let onCreated: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = "~"
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. kino-app"))
                TextField("Verzeichnis", text: $directory, prompt: Text("~/dev/projekt"))
                    .technicalInput()
                if !directory.isEmpty {
                    Text(connection.absolutePath(directory))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Neuer Space auf \(connection.config.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .disabled(creating)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 260)
        #endif
    }

    private func create() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let created = try await connection.createSpace(label: name, directory: directory)
                onCreated(created)
                dismiss()
            } catch {
                self.error = inputErrorMessage(error)
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

/// A space the way herdr's sidebar shows it: name, then the branch, then
/// custom values from plugins or agents. A linked worktree is indented and
/// named after its branch.
private struct SpaceRow: View {
    let workspace: WorkspaceItem
    let nested: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if nested {
                Text("└")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
            }
            StatusDot(state: workspace.agentState)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                if let branchLine {
                    Text(branchLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !workspace.tokens.isEmpty {
                    Text(workspace.tokens.map(\.value).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var title: String {
        if nested { return workspace.branch ?? workspace.worktreeName ?? workspace.label }
        return workspace.label
    }

    /// The branch line; a nested worktree already shows its branch as name.
    private var branchLine: String? {
        nested ? nil : workspace.branch
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

/// Host name with its state and a visible menu: a long press for the
/// context menu is hard to find on iPad.
private struct HostHeader<Actions: View>: View {
    let connection: HostConnection
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.config.kind == .local ? "desktopcomputer" : "network")
            Text(connection.config.name)
            Spacer()
            HostStatusLabel(connection: connection)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.borderless)
            .accessibilityLabel("Host-Aktionen")
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
