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
    @Binding var switching: Bool
    @State private var newSpaceOn: HostConnection?
    /// herdr's own switch under "agents": by space ("grouped") or by state.
    @AppStorage("agentOrder") private var agentOrder = AgentOrder.grouped
    /// Folded sections as "hostID/spaces" or "hostID/agents", one per line;
    /// kept per device.
    @AppStorage("collapsedSections") private var collapsedSections = ""

    private func isCollapsed(_ hostID: UUID, _ section: String) -> Bool {
        collapsedSections.split(separator: "\n").contains { $0 == "\(hostID.uuidString)/\(section)" }
    }

    private func toggle(_ hostID: UUID, _ section: String) {
        let key = "\(hostID.uuidString)/\(section)"
        var keys = Set(collapsedSections.split(separator: "\n").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        withAnimation(.snappy) { collapsedSections = keys.sorted().joined(separator: "\n") }
    }

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
            ToolbarItem(placement: .primaryAction) {
                Button("Schnell wechseln", systemImage: "magnifyingglass") { switching = true }
                    .help(String(localized: "Space oder Agent suchen (⌘K)"))
                    .disabled(store.connections.isEmpty)
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
        let spacesFolded = isCollapsed(connection.id, "spaces")
        HStack {
            SectionToggle(
                title: String(localized: "Spaces"),
                collapsed: spacesFolded,
                summary: spacesFolded ? "\(update.workspaces.count)" : nil
            ) { toggle(connection.id, "spaces") }
            Spacer()
            if connection.config.inputAllowed && connection.isLive {
                Button("Neuer Space", systemImage: "plus") { newSpaceOn = connection }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        if !spacesFolded {
            ForEach(SpaceOrder.arrange(update.workspaces), id: \.workspace.workspaceId) { entry in
                SpaceRow(workspace: entry.workspace, nested: entry.nested)
                    .tag(SpaceRef(hostID: connection.id, workspaceID: entry.workspace.workspaceId))
            }
        }
        if !update.board.isEmpty {
            let agentsFolded = isCollapsed(connection.id, "agents")
            let waiting = update.board.filter { $0.agentState == .blocked }.count
            HStack {
                SectionToggle(
                    title: String(localized: "Agents"),
                    collapsed: agentsFolded,
                    // Folded, waiting agents must still be visible.
                    summary: agentsFolded
                        ? (waiting > 0 ? String(localized: "\(update.board.count), \(waiting) wartet") : "\(update.board.count)")
                        : nil,
                    attention: agentsFolded && waiting > 0
                ) { toggle(connection.id, "agents") }
                Spacer()
                Button(agentOrder.label) { agentOrder = agentOrder.next }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(String(localized: "Sortierung umschalten"))
            }
            if !agentsFolded {
                ForEach(AgentOrder.sorted(update, by: agentOrder), id: \.agent.paneId) { entry in
                    AgentRow(agent: entry.agent, tabNumber: entry.tabNumber)
                        .tag(SpaceRef(hostID: connection.id, workspaceID: entry.agent.workspaceId, paneID: entry.agent.paneId))
                }
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

/// "spaces" / "agents" header that folds its section. Folded, it shows a
/// short summary such as the number of entries.
private struct SectionToggle: View {
    let title: String
    let collapsed: Bool
    var summary: String?
    var attention = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                SubHeader(title: title)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(attention ? AgentState.blocked.color : .secondary)
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "\(title) aufklappen" : "\(title) zuklappen")
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

/// An agent the way herdr's sidebar shows it by default: state, space and
/// tab number (only when the space has several tabs), then the agent.
private struct AgentRow: View {
    let agent: BoardItem
    let tabNumber: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusDot(state: agent.agentState)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tabNumber.map { "\(agent.workspaceLabel) · \($0)" } ?? agent.workspaceLabel)
                        .lineLimit(1)
                    if agent.agentState != .idle {
                        Text(agent.agentState.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(agent.agentState.color)
                    }
                }
                Text(agent.agent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Order of the agents list, switchable like in herdr.
enum AgentOrder: String {
    /// Space order, then tab: herdr's default ("grouped").
    case grouped
    /// Waiting first, then working, done, idle.
    case status

    var label: String {
        switch self {
        case .grouped: String(localized: "grouped")
        case .status: String(localized: "nach Status")
        }
    }

    var next: AgentOrder { self == .grouped ? .status : .grouped }

    struct Entry {
        let agent: BoardItem
        /// Tab label, only when the agent's space has more than one tab.
        let tabNumber: String?
    }

    static func sorted(_ update: SessionUpdate, by order: AgentOrder) -> [Entry] {
        let spaces = SpaceOrder.arrange(update.workspaces).map(\.workspace)
        // The data comes from the server; duplicate ids must not crash the
        // app (uniqueKeysWithValues traps), the first entry wins.
        let spaceIndex = Dictionary(spaces.enumerated().map { ($1.workspaceId, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(update.workspaces.flatMap(\.tabs).map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
        let tabCount = Dictionary(update.workspaces.map { ($0.workspaceId, $0.tabs.count) }, uniquingKeysWith: { first, _ in first })

        // The board arrives sorted by urgency; keep that as the tie-breaker.
        let ranked = update.board.enumerated().map { (index: $0, agent: $1) }
        let ordered = ranked.sorted { a, b in
            let place = { (item: (index: Int, agent: BoardItem)) in
                (spaceIndex[item.agent.workspaceId] ?? Int.max, Int(tabs[item.agent.tabId]?.number ?? UInt32.max))
            }
            switch order {
            case .grouped:
                return (place(a).0, place(a).1, a.index) < (place(b).0, place(b).1, b.index)
            case .status:
                return (a.agent.agentState.urgency, place(a).0, place(a).1, a.index)
                    < (b.agent.agentState.urgency, place(b).0, place(b).1, b.index)
            }
        }
        return ordered.map { item in
            Entry(
                agent: item.agent,
                tabNumber: (tabCount[item.agent.workspaceId] ?? 0) > 1 ? item.agent.tabLabel : nil
            )
        }
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
