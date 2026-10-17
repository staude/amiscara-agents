import SwiftUI

/// A space as herdr shows it: tabs along the top, then the selected pane.
/// A split tab gets a pane picker under the tab bar.
struct WorkspaceDetailView: View {
    @Environment(HostStore.self) private var store
    let selection: SpaceRef?
    @State private var tabID: String?
    @State private var paneID: String?
    @State private var tabError: String?
    /// Kinds for "new tab with agent", from the host's herdr.
    @State private var agentKinds: [String] = []
    @State private var startingAgent = false

    var body: some View {
        Group {
            if let selection,
               let connection = store.connection(for: selection.hostID),
               let workspace = connection.update?.workspaces.first(where: { $0.workspaceId == selection.workspaceID }) {
                VStack(spacing: 0) {
                    tabBar(workspace, connection: connection)
                    if let tabError {
                        Text(tabError).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
                    }
                    if let tab = currentTab(workspace), tab.panes.count > 1 {
                        panePicker(tab)
                    }
                    Divider()
                    PaneDetailView(selection: paneID.map { PaneRef(hostID: connection.id, paneID: $0) })
                }
                .navigationTitle(workspace.worktreeName ?? workspace.label)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                ContentUnavailableView(
                    "Kein Space gewählt",
                    systemImage: "square.split.2x1",
                    description: Text("Wählen Sie links einen Space oder einen Agent.")
                )
            }
        }
        .onChange(of: selection, initial: true) { _, selection in
            focus(on: selection)
        }
        .onChange(of: paneID, initial: true) { _, pane in
            store.notifier.visiblePane = selection.flatMap { selection in
                pane.map { (hostID: selection.hostID, paneID: $0) }
            }
        }
    }

    private func currentTab(_ workspace: WorkspaceItem) -> TabItem? {
        workspace.tabs.first { $0.tabId == tabID }
    }

    private func tabBar(_ workspace: WorkspaceItem, connection: HostConnection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs, id: \.tabId) { tab in
                    Button {
                        select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.label)
                            if tab.agentState != .idle && tab.agentState != .unknown {
                                StatusDot(state: tab.agentState)
                            }
                        }
                        .font(.callout.monospaced())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            isCurrent(tab) ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                if connection.config.inputAllowed && connection.isLive {
                    Button("Neuer Tab", systemImage: "plus") {
                        newTab(in: workspace, on: connection)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    agentTabMenu(in: workspace, on: connection)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    /// "New tab with agent": the usual kinds directly, the rest one level down.
    private func agentTabMenu(in workspace: WorkspaceItem, on connection: HostConnection) -> some View {
        let common = Array(agentKinds.prefix(5))
        let more = Array(agentKinds.dropFirst(5))
        return Menu {
            Section("Neuer Tab mit Agent") {
                ForEach(common, id: \.self) { kind in
                    Button(kind) { newTab(in: workspace, on: connection, agent: kind) }
                }
            }
            if !more.isEmpty {
                Menu("Weitere") {
                    ForEach(more, id: \.self) { kind in
                        Button(kind) { newTab(in: workspace, on: connection, agent: kind) }
                    }
                }
            }
        } label: {
            Label("Neuer Tab mit Agent", systemImage: "sparkles")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
        .padding(.trailing, 8)
        .disabled(startingAgent)
        .help(String(localized: "Neuer Tab mit Agent"))
        .task(id: connection.id) { agentKinds = await connection.agentKinds() }
    }

    private func panePicker(_ tab: TabItem) -> some View {
        Picker("Pane", selection: Binding(get: { paneID ?? "" }, set: { paneID = $0 })) {
            ForEach(tab.panes, id: \.paneId) { pane in
                Text(pane.agent ?? (pane.title.isEmpty ? pane.paneId : pane.title)).tag(pane.paneId)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// The selected tab; right after creating a tab or space the snapshot
    /// may not know `tabID` yet, so the pane decides.
    private func isCurrent(_ tab: TabItem) -> Bool {
        tab.tabId == tabID || (tabID == nil && tab.panes.contains { $0.paneId == paneID })
    }

    /// Creates a tab and shows it; with `agent` that agent starts in its shell.
    private func newTab(in workspace: WorkspaceItem, on connection: HostConnection, agent: String? = nil) {
        tabError = nil
        Task {
            let created: Created
            do {
                created = try await connection.createTab(in: workspace.workspaceId)
                tabID = created.tabId
                paneID = created.paneId
            } catch {
                tabError = inputErrorMessage(error)
                return
            }
            guard let agent else { return }
            startingAgent = true
            defer { startingAgent = false }
            do {
                _ = try await connection.startAgent(kind: agent, in: created.paneId)
            } catch {
                tabError = agentStartErrorMessage(error)
            }
        }
    }

    private func select(_ tab: TabItem) {
        tabID = tab.tabId
        paneID = (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
    }

    /// An agent picks its own tab and pane; a space opens on herdr's active tab.
    private func focus(on selection: SpaceRef?) {
        tabError = nil
        guard let selection,
              let workspace = store.connection(for: selection.hostID)?.update?.workspaces
                .first(where: { $0.workspaceId == selection.workspaceID })
        else {
            // A space created a moment ago is not in the snapshot yet; its
            // first pane is known already.
            tabID = nil
            paneID = selection?.paneID
            return
        }
        if let pane = selection.paneID,
           let tab = workspace.tabs.first(where: { $0.panes.contains { $0.paneId == pane } }) {
            tabID = tab.tabId
            paneID = pane
        } else if let tab = workspace.tabs.first(where: { $0.tabId == workspace.activeTabId }) ?? workspace.tabs.first {
            select(tab)
        }
    }
}
