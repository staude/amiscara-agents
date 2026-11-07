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
    #if !os(tvOS)
    /// Claude Code sessions of the space's folder to resume (#304).
    @State private var claudeSessionsFor: ClaudeSessionsTarget?
    /// The space a new tab with an agent and a first prompt is for (#344).
    @State private var newAgentTabIn: NewAgentTabTarget?
    /// The repository whose existing worktrees are offered (#343).
    @State private var openWorktreeFrom: OpenWorktreeTarget?
    #endif
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
    #if !os(tvOS)
    /// The space's pull request, shown (#309).
    @State private var pullRequestShown: PullRequestTarget?
    /// The uncommitted changes of the space, shown (#342).
    @State private var changesShown: ChangesTarget?
    #endif
    /// The space and pane reopened on launch (#276), set by `ContentView`:
    /// not opened on purpose, so a tab put away meanwhile (#333) stays away.
    @MainActor static var reopened: SpaceRef?

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
                .onChange(of: SettledTabs.shared.tabs(host: connection.settledHost)) { _, settled in
                    settledElsewhere(settled, in: workspace, on: connection)
                }
                .focusedSceneValue(
                    \.tabNavigator,
                    visibleTabs(workspace, on: connection).count > 1
                        ? TabNavigator(step: { step(by: $0, in: workspace, on: connection) }) : nil
                )
                .focusedSceneValue(\.spaceCommands, commands(workspace, on: connection))
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
        #if !os(tvOS)
        .sheet(item: $pullRequestShown) { target in
            PullRequestView(connection: target.connection, pullRequest: target.pullRequest)
        }
        .sheet(item: $changesShown) { target in
            DiffView(connection: target.connection, target: .space(target.workspaceID))
        }
        #endif
        #if !os(tvOS)
        .sheet(item: $newAgentTabIn) { target in
            NewAgentTabView(connection: target.connection, workspace: target.workspace) { created in
                tabID = created.tabId
                paneID = created.paneId
            }
        }
        #endif
        .sheet(item: $newWorktreeFrom) { source in
            NewWorktreeView(source: source) { created in
                selection = SpaceRef(hostID: source.connection.id, workspaceID: created.workspaceId, paneID: created.paneId)
            }
        }
        #if !os(tvOS)
        .sheet(item: $claudeSessionsFor) { target in
            ClaudeSessionsView(target: target) { created in
                tabID = created.tabId
                paneID = created.paneId
            }
        }
        .sheet(item: $openWorktreeFrom) { target in
            OpenWorktreeView(target: target) { created in
                selection = SpaceRef(hostID: target.connection.id, workspaceID: created.workspaceId, paneID: created.paneId.isEmpty ? nil : created.paneId)
            }
        }
        #endif
        .onChange(of: selection, initial: true) { _, selection in
            focus(on: selection, opened: true)
            #if !os(tvOS)
            if let selection { store.connection(for: selection.hostID)?.gitStatus.spaceOpened() }
            #endif
        }
        .onChange(of: isKnown) { _, known in
            // The host lists the space only now (a launch while offline, a
            // space created a moment ago): its tab.
            if known, tabID == nil { focus(on: selection, opened: true) }
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

    /// The tabs of the tab bar: all but those put away (#333).
    private func visibleTabs(_ workspace: WorkspaceItem, on connection: HostConnection) -> [TabItem] {
        let settled = SettledTabs.shared.tabs(host: connection.settledHost)
        return workspace.tabs.filter { !settled.contains($0.tabId) }
    }

    /// The tabs of the space put away (#333), in herdr's order.
    private func settledTabs(_ workspace: WorkspaceItem, on connection: HostConnection) -> [TabItem] {
        let settled = SettledTabs.shared.tabs(host: connection.settledHost)
        return workspace.tabs.filter { settled.contains($0.tabId) }
    }

    /// The last visible tab of a space stays, so the space never looks
    /// empty. A waiting agent's tab stays too: it would come right back.
    private func canSettle(_ tab: TabItem, in workspace: WorkspaceItem, on connection: HostConnection) -> Bool {
        tab.agentState != .blocked && visibleTabs(workspace, on: connection).count > 1
    }

    /// Puts a tab away; the shown one hands over to its neighbour first.
    private func settle(_ tab: TabItem, in workspace: WorkspaceItem, on connection: HostConnection) {
        if isCurrent(tab), let next = neighbour(of: tab.tabId, in: workspace, on: connection) {
            select(next)
            // The neighbour is the tab to come back to.
            remember()
        }
        dropPane(of: tab.tabId, in: workspace)
        SettledTabs.shared.settle(tab: tab.tabId, host: connection.settledHost)
    }

    /// Tabs put away on another device (#333): the tab next to the shown one.
    private func settledElsewhere(_ settled: Set<String>, in workspace: WorkspaceItem, on connection: HostConnection) {
        if let pane = selection?.paneID,
           let tab = workspace.tabs.first(where: { $0.panes.contains { $0.paneId == pane } }),
           settled.contains(tab.tabId) {
            dropPane(of: tab.tabId, in: workspace)
        }
        guard let tabID, settled.contains(tabID) else { return }
        if let next = neighbour(of: tabID, in: workspace, on: connection) {
            select(next)
            remember()
        } else {
            focus(on: selection)
        }
    }

    /// A selection that names a pane of a tab put away drops the pane, so
    /// opening that agent again is a change and brings the tab back.
    private func dropPane(of tabID: String, in workspace: WorkspaceItem) {
        guard let pane = selection?.paneID,
              workspace.tabs.first(where: { $0.tabId == tabID })?.panes.contains(where: { $0.paneId == pane }) == true
        else { return }
        selection?.paneID = nil
    }

    /// The visible tab right of `tabID`, else left of it.
    private func neighbour(of tabID: String, in workspace: WorkspaceItem, on connection: HostConnection) -> TabItem? {
        let settled = SettledTabs.shared.tabs(host: connection.settledHost)
        guard let index = workspace.tabs.firstIndex(where: { $0.tabId == tabID }) else { return nil }
        let shown = { (tab: TabItem) in !settled.contains(tab.tabId) }
        return workspace.tabs[(index + 1)...].first(where: shown) ?? workspace.tabs[..<index].last(where: shown)
    }

    private func tabBar(_ workspace: WorkspaceItem, connection: HostConnection) -> some View {
        // Time in state (#338): the live board, the Mac's board fills gaps.
        let items = (connection.update?.board ?? []).filter { $0.workspaceId == workspace.workspaceId }
        let cloud = AgentOverview.newestBoard(
            for: CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey),
            in: store.cloudBoards
        )
        let settled = settledTabs(workspace, on: connection)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(visibleTabs(workspace, on: connection), id: \.tabId) { tab in
                    Button {
                        select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            // The focused pane's program, else the first's (#337).
                            ProgramIcon(program: (tab.panes.first(where: \.focused) ?? tab.panes.first)?.program, size: 13)
                            Text(tab.label)
                            if tab.agentState != .idle && tab.agentState != .unknown {
                                StatusDot(state: tab.agentState)
                            }
                            if let since = TabTime.since(
                                state: WidgetSnapshot.State(tab.agentState),
                                agents: items.filter { $0.tabId == tab.tabId }.map(WidgetSnapshot.Agent.init),
                                board: cloud
                            ) {
                                TimelineView(.everyMinute) { context in
                                    if let label = TabTime.label(since: since, now: context.date) {
                                        Text(label)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel(
                                                tab.agentState == .working
                                                    ? String(localized: "Arbeitet seit \(label)")
                                                    : String(localized: "Wartet seit \(label)")
                                            )
                                    }
                                }
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
                    .contextMenu(when: RenameTarget.available(on: connection) || canSettle(tab, in: workspace, on: connection)) {
                        if RenameTarget.available(on: connection) {
                            Button("Umbenennen …", systemImage: "pencil") {
                                renaming = RenameTarget(connection: connection, kind: .tab(tabID: tab.tabId), current: tab.label)
                            }
                        }
                        if canSettle(tab, in: workspace, on: connection) {
                            Button("Wegräumen", systemImage: "tray.and.arrow.down") {
                                settle(tab, in: workspace, on: connection)
                            }
                        }
                        if RenameTarget.available(on: connection) {
                            Button("Tab schließen …", systemImage: "xmark", role: .destructive) {
                                closing = closeTarget(tab, on: connection)
                            }
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
                if !settled.isEmpty {
                    settledMenu(settled, on: connection)
                }
                #if !os(tvOS)
                // Where the Git status runs on its own (herdr-core, #359) only
                // for a space with changes. Elsewhere in every Git space,
                // without input too, like "Heute": the sheet says why it
                // needs input; the count once the Git status or a load of
                // the changes knows it (#342).
                if connection.isLive,
                   case .shown(let count) = changesButton(
                       automatic: connection.gitStatus.automatic,
                       gitSpace: workspace.repoKey != nil,
                       statusChanges: connection.gitStatus.status(for: workspace.workspaceId)?.changes,
                       loadedCount: connection.changeCounts[workspace.workspaceId]
                   ) {
                    Button {
                        changesShown = ChangesTarget(connection: connection, workspaceID: workspace.workspaceId)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plusminus")
                            if let count {
                                Text(count, format: .number)
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .help(String(localized: "Nicht committete Änderungen im Space"))
                    .accessibilityLabel(Text("Änderungen"))
                }
                // Reading and merging go to GitHub, not the host's input.
                if let pullRequest = connection.pullRequests.pullRequest(for: workspace.workspaceId) {
                    Button {
                        pullRequestShown = PullRequestTarget(connection: connection, pullRequest: pullRequest)
                    } label: {
                        PullRequestBadge(pullRequest: pullRequest)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .help(String(localized: "Pull Request #\(pullRequest.number)"))
                }
                #endif
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
            #if !os(tvOS)
            Button("Neuer Tab mit Aufgabe …", systemImage: "text.badge.plus") {
                newAgentTabIn = NewAgentTabTarget(connection: connection, workspace: workspace)
            }
            if OpenWorktreeTarget.available(for: workspace, on: connection) {
                Button("Worktree öffnen …", systemImage: "folder.badge.plus") {
                    openWorktreeFrom = OpenWorktreeTarget(connection: connection, workspace: workspace)
                }
            }
            Button("Claude-Sitzungen …", systemImage: "clock.arrow.circlepath") {
                claudeSessionsFor = ClaudeSessionsTarget(connection: connection, workspaceID: workspace.workspaceId, paneID: paneID)
            }
            // A space of herdr desktop has no repository key; its Git
            // status tells it is in a checkout (#359).
            if workspace.repoKey != nil || connection.gitStatus.status(for: workspace.workspaceId) != nil {
                Button("Änderungen …", systemImage: "plusminus") {
                    changesShown = ChangesTarget(connection: connection, workspaceID: workspace.workspaceId)
                }
            }
            #endif
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
                if let tab = visibleTabs(workspace, on: connection).first(where: isCurrent),
                   canSettle(tab, in: workspace, on: connection) {
                    Button("Tab wegräumen", systemImage: "tray.and.arrow.down") {
                        settle(tab, in: workspace, on: connection)
                    }
                }
                if let tab = workspace.tabs.first(where: isCurrent) {
                    Button("Tab schließen …", systemImage: "xmark", role: .destructive) {
                        closing = closeTarget(tab, on: connection)
                    }
                }
                #if !os(tvOS)
                if CloseTarget.worktreeRemovable(workspace, on: connection) {
                    Button("Worktree entfernen …", systemImage: "trash", role: .destructive) {
                        closing = .worktree(workspace, on: connection)
                    }
                }
                #endif
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

    /// The tabs put away (#333), to bring one or all of them back.
    private func settledMenu(_ tabs: [TabItem], on connection: HostConnection) -> some View {
        Menu {
            ForEach(tabs, id: \.tabId) { tab in
                Button {
                    SettledTabs.shared.unsettle(tab: tab.tabId, host: connection.settledHost)
                    select(tab)
                } label: {
                    Text(verbatim: tab.label)
                }
            }
            Divider()
            Button("Alle zurückholen", systemImage: "tray.and.arrow.up") {
                SettledTabs.shared.unsettleAll(host: connection.settledHost, tabs: Set(tabs.map(\.tabId)))
            }
        } label: {
            HStack(spacing: 3) {
                Label("Weggeräumte Tabs", systemImage: "tray.full")
                    .labelStyle(.iconOnly)
                Text(verbatim: "\(tabs.count)")
                    .font(.caption.monospacedDigit())
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
        .padding(.trailing, 8)
        .help(String(localized: "Weggeräumte Tabs"))
    }

    /// What the tab bar and its menus offer, for the switcher (#346): with
    /// input allowed the writing ones, always the pull request, putting a
    /// tab away and stepping through the tabs.
    private func commands(_ workspace: WorkspaceItem, on connection: HostConnection) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        func add(_ id: String, _ title: String, shortcut: CommandShortcut? = nil, keywords: [String] = [], run: @escaping @MainActor () -> Void) {
            commands.append(PaletteCommand(id: "space.\(id)", title: title, section: .space, shortcut: shortcut, keywords: keywords, run: run))
        }
        let tab = workspace.tabs.first(where: isCurrent)
        if RenameTarget.available(on: connection) {
            add("newTab", String(localized: "Neuer Tab")) { newTab(in: workspace, on: connection) }
            if !startingAgent {
                for kind in agentKinds {
                    add("newTab.\(kind)", String(localized: "Neuer Tab mit \(kind)"), keywords: ["agent"]) {
                        newTab(in: workspace, on: connection, agent: kind)
                    }
                }
            }
            if let repo = WorktreeSource.repository(of: workspace, in: connection.update?.workspaces ?? []) {
                add("newWorktree", String(localized: "Neuer Worktree …"), keywords: ["git", "branch"]) {
                    newWorktreeFrom = WorktreeSource(connection: connection, repository: repo)
                }
            }
            if let tab {
                add("renameTab", String(localized: "Tab umbenennen …")) {
                    renaming = RenameTarget(connection: connection, kind: .tab(tabID: tab.tabId), current: tab.label)
                }
            }
            add("renameSpace", String(localized: "Space umbenennen …")) {
                renaming = RenameTarget(connection: connection, kind: .space(workspaceID: workspace.workspaceId), current: workspace.label)
            }
            if let paneID, let pane = tab?.panes.first(where: { $0.paneId == paneID }), pane.agent != nil {
                add("renameAgent", String(localized: "Agent benennen …")) {
                    renaming = RenameTarget(connection: connection, kind: .agent(paneID: paneID), current: pane.name ?? "")
                }
            }
            if let tab {
                add("closeTab", String(localized: "Tab schließen …")) { closing = closeTarget(tab, on: connection) }
            }
            add("closeSpace", String(localized: "Space schließen …")) { closing = .space(workspace, on: connection) }
            #if !os(tvOS)
            add("claudeSessions", String(localized: "Claude-Sitzungen …"), keywords: ["resume"]) {
                claudeSessionsFor = ClaudeSessionsTarget(connection: connection, workspaceID: workspace.workspaceId, paneID: paneID)
            }
            #endif
        }
        if let tab, canSettle(tab, in: workspace, on: connection) {
            add("settleTab", String(localized: "Tab wegräumen")) { settle(tab, in: workspace, on: connection) }
        }
        #if !os(tvOS)
        if let pullRequest = connection.pullRequests.pullRequest(for: workspace.workspaceId) {
            add("pullRequest", String(localized: "Pull Request #\(pullRequest.number) …"), keywords: ["pr", "github"]) {
                pullRequestShown = PullRequestTarget(connection: connection, pullRequest: pullRequest)
            }
        }
        #endif
        if visibleTabs(workspace, on: connection).count > 1 {
            add("previousTab", String(localized: "Vorheriger Tab"), shortcut: Shortcuts.previousTab) {
                step(by: -1, in: workspace, on: connection)
            }
            add("nextTab", String(localized: "Nächster Tab"), shortcut: Shortcuts.nextTab) {
                step(by: 1, in: workspace, on: connection)
            }
        }
        return commands
    }

    private func closeTarget(_ tab: TabItem, on connection: HostConnection) -> CloseTarget {
        CloseTarget(connection: connection, kind: .tab(tabID: tab.tabId), name: tab.label, agentState: tab.agentState)
    }

    private func panePicker(_ tab: TabItem) -> some View {
        Picker("Pane", selection: Binding(get: { paneID ?? "" }, set: { paneID = $0 })) {
            // Sub-agents (#330) after their parent, marked.
            let panes = SubAgentTree.nest(tab.panes, id: \.paneId, parent: \.parentPaneId)
            ForEach(panes, id: \.item.paneId) { pane, depth in
                let name = pane.name ?? pane.agent ?? (pane.title.isEmpty ? pane.paneId : pane.title)
                Text(depth > 0 ? "↳ \(name)" : name).tag(pane.paneId)
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
    private func step(by offset: Int, in workspace: WorkspaceItem, on connection: HostConnection) {
        let tabs = visibleTabs(workspace, on: connection)
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
    /// returns to the tab shown last, else herdr's active tab. Put away
    /// tabs (#333) count only when `opened` on purpose, through their pane:
    /// not when the shown tab closed and the selection still names a pane.
    private func focus(on selection: SpaceRef?, opened: Bool = false) {
        tabError = nil
        // Another selection ends the launch: the reopened pane chosen again
        // later is opened on purpose.
        if selection != Self.reopened { Self.reopened = nil }
        let opened = opened && (selection == nil || selection != Self.reopened)
        guard let selection,
              let connection = store.connection(for: selection.hostID),
              let workspace = connection.update?.workspaces
                .first(where: { $0.workspaceId == selection.workspaceID })
        else {
            // A space created a moment ago is not in the snapshot yet; its
            // first pane is known already.
            tabID = nil
            paneID = selection?.paneID
            return
        }
        let visible = visibleTabs(workspace, on: connection)
        Self.reopened = nil
        if let pane = selection.paneID,
           let tab = (opened ? workspace.tabs : visible).first(where: { $0.panes.contains { $0.paneId == pane } }) {
            // From the agent list, a notification or the switcher: the tab
            // comes back, the tab bar would miss it otherwise.
            SettledTabs.shared.unsettle(tab: tab.tabId, host: connection.settledHost)
            tabID = tab.tabId
            paneID = pane
        } else if let last = LastTabs.shared.entry(host: selection.hostID, workspace: selection.workspaceID),
                  let tab = visible.first(where: { $0.tabId == last.tab }) {
            tabID = tab.tabId
            paneID = last.pane.flatMap { id in tab.panes.contains { $0.paneId == id } ? id : nil }
                ?? (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
        } else if let tab = visible.first(where: { $0.tabId == workspace.activeTabId }) ?? visible.first {
            select(tab)
        } else if let tab = workspace.tabs.first(where: { $0.tabId == workspace.activeTabId }) ?? workspace.tabs.first {
            // Every tab put away, e.g. after closing the last shown one:
            // herdr's active tab comes back.
            SettledTabs.shared.unsettle(tab: tab.tabId, host: connection.settledHost)
            select(tab)
        }
    }
}
