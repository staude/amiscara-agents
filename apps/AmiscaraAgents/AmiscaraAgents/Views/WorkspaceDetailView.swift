import SwiftUI

/// A space as herdr shows it: tabs along the top, then the selected pane.
/// A split tab shows all its panes side by side where there is room (Mac,
/// iPad in regular width), on the iPhone a pane picker under the tab bar.
struct WorkspaceDetailView: View {
    @Environment(HostStore.self) private var store
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// A binding so a new worktree opened from here can be selected.
    @Binding var selection: SpaceRef?
    /// Long presses in the sidebar are unreliable on iPad, so the worktree
    /// sheet is also reachable from the menu next to the tab "+".
    @State private var newWorktreeFrom: WorktreeSource?
    @State private var tabID: String?
    @State private var paneID: String?
    /// The choice question in the selected pane of a split tab (#272).
    @State private var question: ChoiceQuestion?
    @State private var tabError: String?
    /// Kinds for "new tab with agent", from the host's herdr.
    @State private var agentKinds: [String] = []
    @State private var startingAgent = false
    @State private var renaming: RenameTarget?
    @State private var closing: CloseTarget?

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
                    if let tab = currentTab(workspace), let layout = sideBySide(tab) {
                        Divider()
                        SplitTabView(connection: connection, tab: tab, layout: layout, selection: $paneID, question: $question)
                        if connection.config.inputAllowed, let pane = tab.panes.first(where: { $0.paneId == paneID }) {
                            Divider()
                            InputBar(connection: connection, pane: pane, question: question)
                        }
                    } else {
                        if let tab = currentTab(workspace), tab.panes.count > 1 {
                            panePicker(tab)
                        }
                        Divider()
                        PaneDetailView(selection: paneID.map { PaneRef(hostID: connection.id, paneID: $0) })
                    }
                }
                .onChange(of: workspace.tabs.map(\.tabId)) { _, tabs in
                    // The shown tab was closed: herdr's active tab instead.
                    if let tabID, !tabs.contains(tabID) { focus(on: selection) }
                    remember()
                }
                .focusedSceneValue(\.tabNavigator, workspace.tabs.count > 1 ? TabNavigator(step: { step(by: $0, in: workspace) }) : nil)
                .navigationTitle(workspace.worktreeName ?? workspace.name)
                #if !os(tvOS)
                .navigationSubtitle(workspace.group ?? "")
                // Handoff (#231): the other devices offer this pane.
                .userActivity(PaneHandoff.activityType) { activity in
                    activity.isEligibleForHandoff = PaneHandoff.describe(
                        activity,
                        connection: connection,
                        workspaceID: workspace.workspaceId,
                        paneID: paneID,
                        title: workspace.worktreeName ?? workspace.name
                    )
                }
                #endif
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else if let selection,
                      let connection = store.connection(for: selection.hostID),
                      !connection.isLive,
                      let pane = keptPane(for: selection) {
                // Before the host lists its spaces, e.g. after a launch while
                // offline: the pane's last screen, without tabs or input (#276).
                PaneDetailView(selection: PaneRef(hostID: connection.id, paneID: pane))
                    .navigationTitle(keptSpaceName(for: selection) ?? connection.config.name)
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
        .sheet(item: $renaming) { target in
            RenameView(target: target)
        }
        .closeConfirmation($closing)
        .sheet(item: $newWorktreeFrom) { source in
            NewWorktreeView(source: source) { created in
                selection = SpaceRef(hostID: source.connection.id, workspaceID: created.workspaceId, paneID: created.paneId)
            }
        }
        .onChange(of: selection, initial: true) { _, selection in
            focus(on: selection)
        }
        .onChange(of: isKnown) { _, known in
            // The host lists the space only now (a launch while offline, a
            // space created a moment ago): its tab.
            if known, tabID == nil { focus(on: selection) }
        }
        .onChange(of: isGone) { _, gone in
            // The space shown last was closed on the host: not again on launch.
            guard gone, let selection, let last = PaneCache.shared.lastOpen,
                  last.host == selection.hostID, last.workspace == selection.workspaceID
            else { return }
            PaneCache.shared.lastOpen = nil
        }
        .onChange(of: tabID) { remember() }
        .onChange(of: paneID, initial: true) { _, pane in
            remember()
            store.notifier.visiblePane = selection.flatMap { selection in
                pane.map { (hostID: selection.hostID, paneID: $0) }
            }
        }
    }

    /// Whether the host lists the selected space.
    private var isKnown: Bool {
        guard let selection else { return false }
        return store.connection(for: selection.hostID)?.update?.workspaces
            .contains { $0.workspaceId == selection.workspaceID } ?? false
    }

    /// Whether the live host no longer lists the selected space.
    private var isGone: Bool {
        guard let selection, let connection = store.connection(for: selection.hostID),
              connection.isLive, connection.update != nil
        else { return false }
        return !isKnown
    }

    /// The pane to show for a space the host does not list, if its last
    /// screen is kept.
    private func keptPane(for selection: SpaceRef) -> String? {
        guard let pane = selection.paneID ?? LastTabs.shared.entry(host: selection.hostID, workspace: selection.workspaceID)?.pane,
              PaneCache.shared.entry(host: selection.hostID, pane: pane) != nil
        else { return nil }
        return pane
    }

    private func keptSpaceName(for selection: SpaceRef) -> String? {
        guard let last = PaneCache.shared.lastOpen,
              last.host == selection.hostID, last.workspace == selection.workspaceID
        else { return nil }
        return last.spaceName
    }

    private func currentTab(_ workspace: WorkspaceItem) -> TabItem? {
        workspace.tabs.first { $0.tabId == tabID }
    }

    /// The layout to draw a split tab with, or `nil` for the pane picker:
    /// on a compact width (iPhone, narrow iPad window) the panes would be
    /// too small to read.
    private func sideBySide(_ tab: TabItem) -> SplitLayout? {
        #if os(iOS)
        guard sizeClass == .regular else { return nil }
        #endif
        guard let layout = tab.layout, layout.panes.count > 1 else { return nil }
        return layout
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
                    .renameAction(available: RenameTarget.available(on: connection)) {
                        renaming = RenameTarget(connection: connection, kind: .tab(tabID: tab.tabId), current: tab.label)
                    } more: {
                        Button("Tab schließen …", systemImage: "xmark", role: .destructive) {
                            closing = closeTarget(tab, on: connection)
                        }
                    }
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

    /// "New tab with agent": the usual kinds directly, the rest one level
    /// down. For a Git space also "new worktree", visible here because long
    /// presses in the sidebar are unreliable on iPad.
    private func agentTabMenu(in workspace: WorkspaceItem, on connection: HostConnection) -> some View {
        let common = Array(agentKinds.prefix(5))
        let more = Array(agentKinds.dropFirst(5))
        let repo = WorktreeSource.repository(of: workspace, in: connection.update?.workspaces ?? [])
        return Menu {
            if let repo {
                Button("Neuer Worktree …", systemImage: "arrow.triangle.branch") {
                    newWorktreeFrom = WorktreeSource(connection: connection, repository: repo)
                }
            }
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
            // Here as well: long presses on the tabs are unreliable on iPad.
            Section {
                if let tab = workspace.tabs.first(where: isCurrent) {
                    Button("Tab schließen …", systemImage: "xmark", role: .destructive) {
                        closing = closeTarget(tab, on: connection)
                    }
                }
                Button("Space schließen …", systemImage: "xmark.square", role: .destructive) {
                    closing = .space(workspace, on: connection)
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

    private func closeTarget(_ tab: TabItem, on connection: HostConnection) -> CloseTarget {
        CloseTarget(connection: connection, kind: .tab(tabID: tab.tabId), name: tab.label, agentState: tab.agentState)
    }

    private func panePicker(_ tab: TabItem) -> some View {
        Picker("Pane", selection: Binding(get: { paneID ?? "" }, set: { paneID = $0 })) {
            ForEach(tab.panes, id: \.paneId) { pane in
                Text(pane.name ?? pane.agent ?? (pane.title.isEmpty ? pane.paneId : pane.title)).tag(pane.paneId)
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

    /// ⌘⇧[ and ⌘⇧]: the neighbouring tab, wrapping around like herdr.
    private func step(by offset: Int, in workspace: WorkspaceItem) {
        let tabs = workspace.tabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: isCurrent) ?? 0
        select(tabs[(index + offset % tabs.count + tabs.count) % tabs.count])
    }

    private func select(_ tab: TabItem) {
        tabID = tab.tabId
        paneID = (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
    }

    /// Keeps the shown tab and pane for the next time the space is opened
    /// (#263). Only what the snapshot knows: right after creating a tab it
    /// may not list it yet, and `workspace.tabs` changing calls this again.
    /// Also the space and pane to open on the next launch (#276).
    private func remember() {
        guard let selection, let tabID,
              let workspace = store.connection(for: selection.hostID)?.update?.workspaces
                .first(where: { $0.workspaceId == selection.workspaceID }),
              let tab = workspace.tabs.first(where: { $0.tabId == tabID })
        else { return }
        let pane = paneID.flatMap { id in tab.panes.contains { $0.paneId == id } ? id : nil }
        LastTabs.shared.record(tab: tabID, pane: pane, host: selection.hostID, workspace: selection.workspaceID)
        PaneCache.shared.lastOpen = .init(
            host: selection.hostID,
            workspace: selection.workspaceID,
            pane: pane,
            spaceName: workspace.worktreeName ?? workspace.name
        )
    }

    /// An agent picks its own tab and pane; a space opened without one
    /// returns to the tab shown last, else herdr's active tab.
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
        } else if let last = LastTabs.shared.entry(host: selection.hostID, workspace: selection.workspaceID),
                  let tab = workspace.tabs.first(where: { $0.tabId == last.tab }) {
            tabID = tab.tabId
            paneID = last.pane.flatMap { id in tab.panes.contains { $0.paneId == id } ? id : nil }
                ?? (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
        } else if let tab = workspace.tabs.first(where: { $0.tabId == workspace.activeTabId }) ?? workspace.tabs.first {
            select(tab)
        }
    }
}
