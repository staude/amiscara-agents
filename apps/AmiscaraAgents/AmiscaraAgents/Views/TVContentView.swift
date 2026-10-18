#if os(tvOS)
import SwiftUI

/// The Apple TV's start (#128): a tab bar that is always in reach, with the
/// agents as a board, the spaces per host, and the hosts with pairing.
/// Each tab navigates on its own; the remote's back button returns.
struct TVContentView: View {
    @Binding var editing: HostConfig?

    private enum Section: Hashable {
        case agents, spaces, hosts
    }

    @State private var section = Section.agents

    var body: some View {
        TabView(selection: $section) {
            Tab("Agents", systemImage: "sparkles", value: .agents) {
                NavigationStack { TVBoardView() }
            }
            Tab("Spaces", systemImage: "square.split.2x1", value: .spaces) {
                NavigationStack { TVSpacesView() }
            }
            Tab("Hosts", systemImage: "server.rack", value: .hosts) {
                NavigationStack { TVHostsView(editing: $editing) }
            }
        }
    }
}

/// A space opened from the board or the list, laid out for the remote:
/// rows the focus moves through from top to bottom (tabs, panes, the pane
/// with its header, terminal and input). No navigation bar, so the
/// terminal gets the room.
private struct TVSpaceScreen: View {
    @Environment(HostStore.self) private var store
    let selection: SpaceRef
    @State private var tabID: String?
    @State private var paneID: String?
    @State private var agentKinds: [String] = []
    @State private var error: String?
    @State private var renaming: RenameTarget?
    @State private var closing: CloseTarget?
    @State private var newWorktreeFrom: WorktreeSource?

    private enum Focus: Hashable { case tabs }
    @FocusState private var focus: Focus?

    var body: some View {
        Group {
            if let connection = store.connection(for: selection.hostID),
               let workspace = connection.update?.workspaces.first(where: { $0.workspaceId == selection.workspaceID }) {
                VStack(alignment: .leading, spacing: 12) {
                    tabRow(workspace, connection: connection)
                        .focusSection()
                    if let tab = workspace.tabs.first(where: { $0.tabId == tabID }), tab.panes.count > 1 {
                        Picker("Pane", selection: Binding(get: { paneID ?? "" }, set: { paneID = $0 })) {
                            ForEach(tab.panes, id: \.paneId) { pane in
                                Text(pane.name ?? pane.agent ?? (pane.title.isEmpty ? pane.paneId : pane.title)).tag(pane.paneId)
                            }
                        }
                        .pickerStyle(.segmented)
                        .focusSection()
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    PaneDetailView(selection: paneID.map { PaneRef(hostID: connection.id, paneID: $0) })
                }
                .padding(.horizontal, 40)
                .onChange(of: workspace.tabs.map(\.tabId), initial: true) { _, ids in
                    if tabID == nil || !ids.contains(tabID ?? "") { pick(workspace, pane: selection.paneID) }
                }
                .task(id: connection.id) { agentKinds = await connection.agentKinds() }
            } else {
                ContentUnavailableView("Space nicht verfügbar", systemImage: "square.split.2x1")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .tabs)
        .sheet(item: $renaming) { RenameView(target: $0) }
        .sheet(item: $newWorktreeFrom) { source in
            NewWorktreeView(source: source) { _ in }
        }
        .closeConfirmation($closing)
    }

    private func tabRow(_ workspace: WorkspaceItem, connection: HostConnection) -> some View {
        HStack(spacing: 24) {
            Text(workspace.worktreeName ?? workspace.name)
                .font(.headline)
                .lineLimit(1)
            Picker("Tab", selection: Binding(get: { tabID ?? "" }, set: { select($0, in: workspace) })) {
                ForEach(workspace.tabs, id: \.tabId) { tab in
                    Text(tab.label).tag(tab.tabId)
                }
            }
            .pickerStyle(.segmented)
            .focused($focus, equals: .tabs)
            if connection.config.inputAllowed && connection.isLive {
                Button("Neuer Tab", systemImage: "plus") { newTab(in: workspace, on: connection) }
                    .labelStyle(.iconOnly)
                Menu {
                    ForEach(agentKinds, id: \.self) { kind in
                        Button(kind) { newTab(in: workspace, on: connection, agent: kind) }
                    }
                } label: {
                    Label("Agent starten", systemImage: "sparkles")
                }
                .labelStyle(.iconOnly)
                // A segment has no menu on long press: tab and space
                // actions live here.
                Menu {
                    if let pane = workspace.tabs.flatMap(\.panes).first(where: { $0.paneId == paneID }), pane.agent != nil {
                        Button("Agent benennen …", systemImage: "character.cursor.ibeam") {
                            renaming = RenameTarget(connection: connection, kind: .agent(paneID: pane.paneId), current: pane.name ?? "")
                        }
                    }
                    if let repo = WorktreeSource.repository(of: workspace, in: connection.update?.workspaces ?? []) {
                        Button("Neuer Worktree …", systemImage: "arrow.triangle.branch") {
                            newWorktreeFrom = WorktreeSource(connection: connection, repository: repo)
                        }
                    }
                    if let tab = workspace.tabs.first(where: { $0.tabId == tabID }) {
                        Button("Tab umbenennen …", systemImage: "pencil") {
                            renaming = RenameTarget(connection: connection, kind: .tab(tabID: tab.tabId), current: tab.label)
                        }
                        Button("Tab schließen …", systemImage: "xmark", role: .destructive) {
                            closing = CloseTarget(connection: connection, kind: .tab(tabID: tab.tabId), name: tab.label, agentState: tab.agentState)
                        }
                    }
                    Button("Space umbenennen …", systemImage: "pencil") {
                        renaming = RenameTarget(connection: connection, kind: .space(workspaceID: workspace.workspaceId), current: workspace.label)
                    }
                    Button("Space schließen …", systemImage: "xmark.square", role: .destructive) {
                        closing = .space(workspace, on: connection)
                    }
                } label: {
                    Label("Tab und Space", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
            }
            Spacer(minLength: 0)
        }
    }

    private func pick(_ workspace: WorkspaceItem, pane: String?) {
        if let pane, let tab = workspace.tabs.first(where: { $0.panes.contains { $0.paneId == pane } }) {
            tabID = tab.tabId
            paneID = pane
        } else if let tab = workspace.tabs.first(where: { $0.tabId == workspace.activeTabId }) ?? workspace.tabs.first {
            select(tab.tabId, in: workspace)
        }
    }

    private func select(_ id: String, in workspace: WorkspaceItem) {
        guard let tab = workspace.tabs.first(where: { $0.tabId == id }) else { return }
        tabID = tab.tabId
        paneID = (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
    }

    private func newTab(in workspace: WorkspaceItem, on connection: HostConnection, agent: String? = nil) {
        error = nil
        Task {
            do {
                let created = try await connection.createTab(in: workspace.workspaceId)
                tabID = created.tabId
                paneID = created.paneId
                if let agent {
                    _ = try await connection.startAgent(kind: agent, in: created.paneId)
                }
            } catch {
                self.error = agent == nil ? inputErrorMessage(error) : agentStartErrorMessage(error)
            }
        }
    }
}

extension View {
    /// Pushes a space for a `SpaceRef` link inside the tab's stack.
    fileprivate func spaceDestination() -> some View {
        navigationDestination(for: SpaceRef.self) { ref in
            TVSpaceScreen(selection: ref)
        }
    }
}

// MARK: Agents

/// All agents of all hosts as cards, waiting first.
struct TVBoardView: View {
    @Environment(HostStore.self) private var store

    private var agents: [(connection: HostConnection, agent: BoardItem)] {
        store.connections.flatMap { connection in
            (connection.update?.board ?? []).map { (connection: connection, agent: $0) }
        }
        .enumerated()
        .sorted { ($0.element.agent.agentState.urgency, $0.offset) < ($1.element.agent.agentState.urgency, $1.offset) }
        .map(\.element)
    }

    var body: some View {
        ScrollView {
            if store.connections.isEmpty {
                TVNoHosts()
            } else if agents.isEmpty {
                ContentUnavailableView("Keine Agents", systemImage: "sparkles", description: Text("Auf den Hosts läuft gerade kein Agent."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 40)], spacing: 40) {
                    ForEach(agents, id: \.agent.paneId) { connection, agent in
                        NavigationLink(value: SpaceRef(hostID: connection.id, workspaceID: agent.workspaceId, paneID: agent.paneId)) {
                            card(agent, host: store.connections.count > 1 ? connection.config.name : nil)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
        }
        .spaceDestination()
    }

    private func card(_ agent: BoardItem, host: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusDot(state: agent.agentState)
                Text(agent.agentState.label)
                    .font(.headline)
                    .foregroundStyle(agent.agentState.color)
                Spacer()
                if let host {
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(agent.spacePlace).font(.title3.weight(.semibold)).lineLimit(1)
            Text([agent.name ?? agent.agent, "Tab \(agent.tabLabel)"].joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(agent.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }
}

// MARK: Spaces

/// The spaces of every host in sidebar order.
struct TVSpacesView: View {
    @Environment(HostStore.self) private var store
    @State private var newSpaceOn: HostConnection?

    var body: some View {
        List {
            if store.connections.isEmpty {
                TVNoHosts()
            }
            ForEach(store.connections) { connection in
                Section {
                    if let update = connection.update {
                        ForEach(SpaceOrder.arrange(update), id: \.workspace.workspaceId) { entry in
                            NavigationLink(value: SpaceRef(hostID: connection.id, workspaceID: entry.workspace.workspaceId)) {
                                SpaceRow(workspace: entry.workspace, nested: entry.nested)
                            }
                        }
                    } else {
                        HostStatusLabel(connection: connection)
                    }
                    if connection.config.inputAllowed && connection.isLive {
                        Button("Neuer Space …", systemImage: "plus") { newSpaceOn = connection }
                    }
                } header: {
                    Text(connection.config.name)
                }
            }
        }
        .spaceDestination()
        .sheet(item: $newSpaceOn) { connection in
            // The new space shows up in the list; open it from there.
            NewSpaceView(connection: connection) { _ in }
        }
    }
}

// MARK: Hosts

/// Hosts with their state; pairing and adding as fixed buttons.
struct TVHostsView: View {
    @Environment(HostStore.self) private var store
    @Binding var editing: HostConfig?
    @State private var pairing = false

    var body: some View {
        List {
            Section {
                Button("Mit iPhone koppeln", systemImage: "iphone") { pairing = true }
                Button("Host von Hand hinzufügen", systemImage: "plus") {
                    editing = HostConfig(name: "", kind: .ssh)
                }
            }
            Section("Hosts") {
                ForEach(store.connections) { connection in
                    Button {
                        editing = connection.config
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(connection.config.name)
                                Spacer()
                                Text(connection.isLive ? "verbunden" : "nicht verbunden")
                                    .foregroundStyle(connection.isLive ? .green : .orange)
                            }
                            Text(connection.config.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let problem = problem(connection) {
                                Text(problem)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Neu verbinden", systemImage: "arrow.clockwise") { connection.start() }
                        Button("Entfernen", systemImage: "trash", role: .destructive) { store.remove(connection.id) }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $pairing) { TVPairingView() }
    }

    /// Why a host does not connect, as the core reports it.
    private func problem(_ connection: HostConnection) -> String? {
        if let error = connection.startError { return error }
        switch connection.update?.status {
        case .retrying(_, let error), .failed(let error): return error
        case .hostKeyUnknown: return String(localized: "Host-Key unbekannt")
        case .hostKeyChanged: return String(localized: "Host-Key hat sich geändert")
        default: return nil
        }
    }
}

private struct TVNoHosts: View {
    var body: some View {
        ContentUnavailableView(
            "Keine Hosts",
            systemImage: "server.rack",
            description: Text("Unter „Hosts“ das Apple TV mit dem iPhone koppeln.")
        )
    }
}
#endif
