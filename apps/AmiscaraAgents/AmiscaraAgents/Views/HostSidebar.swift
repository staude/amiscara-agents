import SwiftUI

/// What the sidebar selects: a space, optionally with one of its panes
/// (when an agent was picked).
struct SpaceRef: Hashable, Sendable {
    let hostID: UUID
    let workspaceID: String
    var paneID: String?
}

/// What the sidebar can select: the overview of all hosts (#274) or a
/// space with its agent.
enum SidebarItem: Hashable {
    case overview
    case space(SpaceRef)
}

/// The sidebar, laid out like herdr's own: per host the spaces (linked
/// worktrees indented under their repository's space), then the agents as
/// "space · tab" with the agent below, waiting ones first.
struct HostSidebar: View {
    @Environment(HostStore.self) private var store
    @Binding var selection: SidebarItem?
    @Binding var editing: HostConfig?
    @Binding var switching: Bool
    /// Text from the clipboard to an agent (#236).
    let openHandoff: () -> Void
    @State private var newSpaceOn: HostConnection?
    @State private var showingQR: HostConfig?
    @State private var renaming: RenameTarget?
    @State private var closing: CloseTarget?
    @State private var newWorktreeFrom: WorktreeSource?
    @State private var addingSessionTo: HostConnection?
    /// Why a swipe action on an agent row could not be sent.
    @State private var swipeError: String?
    /// Bumped after a swipe action went out, for the haptic.
    @State private var swipeSent = 0
    /// The entry chosen there, opened in the editor once the list is gone.
    @State private var chosenSession: HostConfig?
    @State private var spaceDrag = SpaceDragState()
    /// herdr's own switch under "agents": by space ("grouped") or by state.
    @AppStorage("agentOrder") private var agentOrder = AgentOrder.grouped
    /// Folded sections as "hostID/spaces", "hostID/agents" or
    /// "hostID/group/<Bereich>" for a name group, one per line; kept per
    /// device.
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
            #if !os(tvOS)
            // The Apple TV has the overview as its first tab.
            if !store.connections.isEmpty {
                Label("Übersicht", systemImage: "square.grid.2x2")
                    .badge(store.overview.waitingCount)
                    .tag(SidebarItem.overview)
            }
            #endif
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
        #if !os(tvOS)
        .listStyle(.sidebar)
        #endif
        .navigationTitle("Amiscara Agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AddHostButton(editing: $editing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Schnell wechseln", systemImage: "magnifyingglass") { switching = true }
                    .help(String(localized: "Space oder Agent suchen (⌘K)"))
                    .disabled(store.connections.isEmpty)
            }
            #if os(iOS)
            // The Mac has it in the "Gehe zu" menu (⌥⌘V).
            ToolbarItem(placement: .primaryAction) {
                Button("Übergabe aus Zwischenablage", systemImage: "doc.on.clipboard", action: openHandoff)
                    .help(String(localized: "Text aus der Zwischenablage an einen Agent übergeben"))
                    .disabled(store.connections.isEmpty)
            }
            // The Mac has its settings window (⌘,) for this.
            ToolbarItem(placement: .secondaryAction) {
                Menu("Erscheinungsbild", systemImage: "circle.lefthalf.filled") {
                    AppearancePicker()
                    Section("Terminal") {
                        TerminalSettings()
                            .pickerStyle(.menu)
                    }
                    Section("App-Sperre") {
                        AppLockSettings()
                            .pickerStyle(.menu)
                    }
                    LiveActivityToggle()
                }
            }
            #endif
        }
        .overlay {
            if store.connections.isEmpty {
                NoHostsView(editing: $editing)
            }
        }
        .sheet(item: $showingQR) { config in
            HostQRView(config: config)
        }
        .sheet(item: $addingSessionTo, onDismiss: {
            if let chosenSession {
                self.chosenSession = nil
                editing = chosenSession
            }
        }) { connection in
            AddSessionView(connection: connection) { chosenSession = $0 }
        }
        .sheet(item: $renaming) { target in
            RenameView(target: target)
        }
        .closeConfirmation($closing)
        .alert("Senden fehlgeschlagen", isPresented: Binding(get: { swipeError != nil }, set: { if !$0 { swipeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(swipeError ?? "")
        }
        #if !os(tvOS)
        .sensoryFeedback(.success, trigger: swipeSent)
        #endif
        .sheet(item: $newSpaceOn) { connection in
            NewSpaceView(connection: connection) { created in
                selection = .space(SpaceRef(hostID: connection.id, workspaceID: created.workspaceId, paneID: created.paneId))
            }
        }
        .sheet(item: $newWorktreeFrom) { source in
            NewWorktreeView(source: source) { created in
                selection = .space(SpaceRef(hostID: source.connection.id, workspaceID: created.workspaceId, paneID: created.paneId))
            }
        }
    }

    @ViewBuilder
    private func hostActions(_ connection: HostConnection) -> some View {
        Button("Bearbeiten …", systemImage: "pencil") { editing = connection.config }
        Button("Neu verbinden", systemImage: "arrow.clockwise") { connection.start() }
        Button("QR-Code zeigen …", systemImage: "qrcode") { showingQR = connection.config }
        Button("Weitere Session hinzufügen …", systemImage: "plus.rectangle.on.rectangle") {
            addingSessionTo = connection
        }
        Divider()
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            store.remove(connection.id)
        }
    }

    /// An agent row with rename in its context menu and, with input
    /// allowed, swipe actions (#230): leading confirms a waiting agent or
    /// sends the first quick reply, trailing has Esc, Ctrl-C and rename.
    @ViewBuilder
    private func agentRow(_ connection: HostConnection, _ entry: AgentOrder.Entry) -> some View {
        let agent = entry.agent
        let row = AgentRow(agent: agent, tabNumber: entry.tabNumber)
            .tag(SidebarItem.space(SpaceRef(hostID: connection.id, workspaceID: agent.workspaceId, paneID: agent.paneId)))
        if RenameTarget.available(on: connection) {
            let rename = {
                renaming = RenameTarget(connection: connection, kind: .agent(paneID: agent.paneId), current: agent.name ?? "")
            }
            row
                .contextMenu {
                    Button("Agent benennen …", systemImage: "pencil", action: rename)
                }
                #if !os(tvOS)
                // No full swipe: a flick through the list must not approve
                // a dialog or interrupt an agent.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if agent.agentState == .blocked {
                        Button("Bestätigen", systemImage: "return") {
                            sendFromRow(agent) { try await connection.send(keys: ["enter"], to: agent.paneId) }
                        }
                        .tint(AgentState.blocked.color)
                    } else if let reply = QuickReplyStore.shared.usable.first {
                        Button(reply.trimmed, systemImage: "arrowshape.turn.up.right") {
                            sendFromRow(agent) { try await connection.submit(reply.trimmed, to: agent.paneId, isAgent: true) }
                        }
                        .tint(.accentColor)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Esc", systemImage: "escape") {
                        sendFromRow(agent) { try await connection.send(keys: ["esc"], to: agent.paneId) }
                    }
                    .tint(.orange)
                    Button("Control-C", systemImage: "xmark.octagon") {
                        sendFromRow(agent) { try await connection.send(keys: ["ctrl+c"], to: agent.paneId) }
                    }
                    .tint(.red)
                    Button("Agent benennen …", systemImage: "pencil", action: rename)
                        .tint(.gray)
                }
                #endif
        } else {
            row
        }
    }

    private func sendFromRow(_ agent: BoardItem, _ action: @escaping @MainActor () async throws -> Void) {
        let name = agent.name ?? agent.agent
        let place = agent.workspaceName
        Task {
            do {
                try await action()
                swipeSent += 1
            } catch {
                swipeError = String(localized: "\(name) in \(place): \(inputErrorMessage(error))")
            }
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
            spaceSortMenu(connection, update)
            if connection.config.inputAllowed && connection.isLive {
                Button("Neuer Space", systemImage: "plus") { newSpaceOn = connection }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        if !spacesFolded {
            let arranged = SpaceOrder.arrange(update)
            // Drag and drop only in the manual order: the others would undo it.
            let reorderable = connection.config.spaceSort == .manual ? arranged : nil
            ForEach(SpaceOrder.blocks(arranged)) { block in
                switch block {
                case .space(let entry):
                    spaceRow(connection, update, entry, grouped: false, reorder: reorderable)
                case .group(let name, let entries):
                    let key = "group/\(name)"
                    let folded = isCollapsed(connection.id, key)
                    let ids = Set(entries.map(\.workspace.workspaceId))
                    SpaceGroupRow(
                        name: name,
                        spaces: entries.count,
                        waiting: update.board.filter { $0.agentState == .blocked && ids.contains($0.workspaceId) }.count,
                        collapsed: folded
                    ) { toggle(connection.id, key) }
                    .spaceReordering(key, on: connection.id, among: reorderable, drag: spaceDrag, foldedLast: folded ? entries.last?.workspace.workspaceId : nil) { reorder(connection, $0, dragged: $1, onto: key) }
                    if !folded {
                        ForEach(entries, id: \.workspace.workspaceId) { entry in
                            spaceRow(connection, update, entry, grouped: true, reorder: reorderable)
                        }
                    }
                }
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
                    agentRow(connection, entry)
                }
            }
        }
    }

    /// herdr's order, by name or manual (#243), per host.
    private func spaceSortMenu(_ connection: HostConnection, _ update: SessionUpdate) -> some View {
        let mode = Binding {
            connection.config.spaceSort ?? .herdr
        } set: { mode in
            // Manual starts from what the sidebar shows now.
            let order = mode == .manual ? update.spaceOrder.map(\.workspaceId) : nil
            store.setSpaceSort(mode, order: order, for: connection.id)
        }
        return Menu(mode.wrappedValue.label) {
            Picker("Spaces sortieren", selection: mode) {
                ForEach(SpaceSortMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
        .font(.caption)
        .help(String(localized: "Spaces sortieren"))
    }

    /// Stores the order after a drop; `false` when the drop is not allowed
    /// there, e.g. a space dropped into another group.
    private func reorder(_ connection: HostConnection, _ entries: [SpaceOrder.Entry], dragged: String, onto target: String) -> Bool {
        guard let order = SpaceOrder.moved(entries, dragged: dragged, onto: target) else { return false }
        store.setSpaceSort(.manual, order: order, for: connection.id)
        return true
    }

    private func spaceRow(_ connection: HostConnection, _ update: SessionUpdate, _ entry: SpaceOrder.Entry, grouped: Bool, reorder entries: [SpaceOrder.Entry]?) -> some View {
        let key = entry.workspace.workspaceId
        return SpaceRow(workspace: entry.workspace, nested: entry.nested, grouped: grouped)
            .tag(SidebarItem.space(SpaceRef(hostID: connection.id, workspaceID: key)))
            .spaceReordering(key, on: connection.id, among: entries, drag: spaceDrag) { reorder(connection, $0, dragged: $1, onto: key) }
            .renameAction(available: RenameTarget.available(on: connection)) {
                renaming = RenameTarget(
                    connection: connection,
                    kind: .space(workspaceID: entry.workspace.workspaceId),
                    current: entry.workspace.label
                )
            } more: {
                if let repo = WorktreeSource.repository(of: entry.workspace, in: update.workspaces) {
                    Button("Neuer Worktree …", systemImage: "arrow.triangle.branch") {
                        newWorktreeFrom = WorktreeSource(connection: connection, repository: repo)
                    }
                }
                Button("Space schließen …", systemImage: "xmark.square", role: .destructive) {
                    closing = .space(entry.workspace, on: connection)
                }
            }
    }
}

/// Name and directory for a new space, optionally with an agent started
/// in its first pane.
struct NewSpaceView: View {
    let connection: HostConnection
    let onCreated: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = "~"
    /// The last choice, so whoever always starts claude picks it once.
    @AppStorage("newSpaceAgentKind") private var agentKind: String?
    @State private var creating = false
    /// Set when the space exists but its agent did not start.
    @State private var createdWithoutAgent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: connection.config.groupSpacesByName ? Text("z. B. Privat/Dorfkino") : Text("z. B. Dorfkino"))
                    TextField("Verzeichnis", text: $directory, prompt: Text("~/dev/projekt"))
                        .technicalInput()
                    if !directory.isEmpty {
                        Text(connection.absolutePath(directory))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if connection.config.groupSpacesByName {
                        Text(SpaceNames.groupHint)
                    }
                }
                AgentPicker(connection: connection, kind: $agentKind)
                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Neuer Space auf \(connection.config.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdWithoutAgent ? "Schließen" : "Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .disabled(creating || createdWithoutAgent)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 340)
        #endif
    }

    private func create() {
        creating = true
        error = nil
        let kind = agentKind
        Task {
            defer { creating = false }
            let created: Created
            do {
                created = try await connection.createSpace(label: name, directory: directory)
            } catch {
                self.error = inputErrorMessage(error)
                return
            }
            onCreated(created)
            if let kind {
                do {
                    _ = try await connection.startAgent(kind: kind, in: created.paneId)
                } catch {
                    // The space exists; "Anlegen" again would make a second one.
                    createdWithoutAgent = true
                    self.error = agentStartErrorMessage(error)
                    return
                }
            }
            dismiss()
        }
    }
}

/// The space a new worktree starts from: herdr wants the repository's main
/// checkout, so a linked worktree hands over to its repository's space.
struct WorktreeSource: Identifiable {
    let connection: HostConnection
    let repository: WorkspaceItem

    var id: String { "\(connection.id.uuidString)/\(repository.workspaceId)" }

    /// `nil` for a space outside Git, or a linked worktree whose main
    /// checkout has no space.
    static func repository(of workspace: WorkspaceItem, in workspaces: [WorkspaceItem]) -> WorkspaceItem? {
        guard workspace.worktreeName != nil else {
            return workspace.branch != nil || workspace.repoKey != nil ? workspace : nil
        }
        return workspaces.first { $0.repoKey == workspace.repoKey && $0.worktreeName == nil }
    }
}

/// Branch, base and name for a new worktree, optionally with an agent
/// started in it. Empty fields are left to herdr.
struct NewWorktreeView: View {
    let source: WorktreeSource
    let onCreated: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var base = ""
    @State private var name = ""
    @AppStorage("newWorktreeAgentKind") private var agentKind: String?
    @State private var creating = false
    /// Set when the worktree exists but its agent did not start.
    @State private var createdWithoutAgent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Branch", text: $branch, prompt: Text("z. B. feature/login"))
                        .technicalInput()
                    TextField("Basis", text: $base, prompt: Text("HEAD"))
                        .technicalInput()
                    TextField("Name", text: $name, prompt: branch.isEmpty ? Text("wie der Branch") : Text(verbatim: branch))
                } footer: {
                    Text("Ohne Branch wählt herdr einen Namen. Einen vorhandenen Branch checkt herdr aus. Der Worktree liegt in herdrs Worktree-Verzeichnis.")
                }
                AgentPicker(connection: source.connection, kind: $agentKind)
                if creating {
                    ProgressView()
                }
                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Neuer Worktree von \(source.repository.label)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdWithoutAgent ? "Schließen" : "Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .disabled(creating || createdWithoutAgent)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 360)
        #endif
    }

    private func create() {
        creating = true
        error = nil
        let kind = agentKind
        let connection = source.connection
        Task {
            defer { creating = false }
            let created: Created
            do {
                created = try await connection.createWorktree(
                    from: source.repository.workspaceId, branch: branch, base: base, label: name
                )
            } catch {
                self.error = inputErrorMessage(error)
                return
            }
            onCreated(created)
            if let kind {
                do {
                    _ = try await connection.startAgent(kind: kind, in: created.paneId)
                } catch {
                    // The worktree exists; "Anlegen" again would fail on the branch.
                    createdWithoutAgent = true
                    self.error = agentStartErrorMessage(error)
                    return
                }
            }
            dismiss()
        }
    }
}

/// The sidebar's order of spaces, worked out by the core: herdr's order or
/// the host's sort, each linked worktree right after its repository's
/// space, and spaces named "Bereich/Name" moved together behind the first
/// of their group.
enum SpaceOrder {
    struct Entry {
        let workspace: WorkspaceItem
        let nested: Bool
    }

    /// A run of the sidebar: one space outside any group, or a name group
    /// with its spaces (worktrees included).
    enum Block: Identifiable {
        case space(Entry)
        case group(String, [Entry])

        var id: String {
            switch self {
            case .space(let entry): "space/\(entry.workspace.workspaceId)"
            case .group(let name, _): "group/\(name)"
            }
        }
    }

    static func arrange(_ update: SessionUpdate) -> [Entry] {
        // The data comes from the server; duplicate ids must not crash the
        // app (uniqueKeysWithValues traps), the first entry wins.
        let byID = Dictionary(update.workspaces.map { ($0.workspaceId, $0) }, uniquingKeysWith: { first, _ in first })
        return update.spaceOrder.compactMap { slot in
            byID[slot.workspaceId].map { Entry(workspace: $0, nested: slot.nested) }
        }
    }

    /// The core keeps a group's spaces adjacent, so a group ends where the
    /// next space has another one.
    static func blocks(_ entries: [Entry]) -> [Block] {
        var blocks: [Block] = []
        for entry in entries {
            guard let group = entry.workspace.group else {
                blocks.append(.space(entry))
                continue
            }
            if case .group(let name, let members) = blocks.last, name == group {
                blocks[blocks.count - 1] = .group(name, members + [entry])
            } else {
                blocks.append(.group(group, [entry]))
            }
        }
        return blocks
    }

    /// Where a dragged row may go: groups and ungrouped spaces at the top,
    /// spaces within their group, worktrees under their repository.
    private enum Level: Equatable {
        case top
        case group(String)
        case worktrees(of: String)
    }

    /// The rows that move with `key` (a workspace ID or `group/<Name>`): a
    /// group with all its entries, a space with its nested worktrees.
    private static func segment(_ key: String, in entries: [Entry]) -> (level: Level, range: Range<Int>)? {
        if let index = entries.firstIndex(where: { $0.workspace.workspaceId == key }) {
            if entries[index].nested {
                guard let head = entries[..<index].lastIndex(where: { !$0.nested }) else { return nil }
                return (.worktrees(of: entries[head].workspace.workspaceId), index..<index + 1)
            }
            let end = entries[(index + 1)...].firstIndex { !$0.nested } ?? entries.endIndex
            return (entries[index].workspace.group.map { .group($0) } ?? .top, index..<end)
        }
        guard key.hasPrefix("group/") else { return nil }
        let name = String(key.dropFirst("group/".count))
        guard let first = entries.firstIndex(where: { $0.workspace.group == name }),
              let last = entries.lastIndex(where: { $0.workspace.group == name }) else { return nil }
        return (.top, first..<last + 1)
    }

    /// The manual order after dropping `dragged` on `target`: behind it when
    /// it came from above, otherwise in front of it. `nil` when both are on
    /// different levels or the same row.
    static func moved(_ entries: [Entry], dragged: String, onto target: String) -> [String]? {
        guard dragged != target,
              let from = segment(dragged, in: entries),
              let to = segment(target, in: entries),
              from.level == to.level else { return nil }
        var ids = entries.map(\.workspace.workspaceId)
        let moving = Array(ids[from.range])
        ids.removeSubrange(from.range)
        let index = from.range.lowerBound < to.range.lowerBound
            ? to.range.upperBound - from.range.count
            : to.range.lowerBound
        ids.insert(contentsOf: moving, at: index)
        return ids
    }

    /// Where `moved` puts the dragged row: at the top edge of `key`, or at
    /// its bottom edge when `below`.
    struct InsertionLine: Equatable {
        let key: String
        let below: Bool
    }

    /// The row at whose edge a drop of `dragged` on `target` lands (#255):
    /// behind the last row of the target when it came from above, otherwise
    /// in front of it. `nil` where `moved` refuses.
    static func insertionLine(_ entries: [Entry], dragged: String, onto target: String) -> InsertionLine? {
        guard dragged != target,
              let from = segment(dragged, in: entries),
              let to = segment(target, in: entries),
              from.level == to.level else { return nil }
        return from.range.lowerBound < to.range.lowerBound
            ? InsertionLine(key: entries[to.range.upperBound - 1].workspace.workspaceId, below: true)
            : InsertionLine(key: target, below: false)
    }
}

/// The row being dragged in the sidebar and the one it hovers, shared by
/// the rows of all hosts. Set by the row the drag enters, from the drop
/// session's dragged item ID: nothing is kept across drags, so a cancelled
/// drag or a foreign one (text from another app) leaves no line behind.
@Observable
final class SpaceDragState {
    struct Hover: Equatable {
        let dragged: String
        let over: String
    }

    var hover: Hover?
}

extension View {
    /// Drag and drop for the manual order of spaces (#243). `key` is a
    /// workspace ID or `group/<Name>`; `entries` is the sidebar's order, or
    /// `nil` outside the manual order. `onDrop` gets it with the dragged key.
    /// The dragged text carries the host, because herdr numbers the IDs per
    /// server and group names repeat: a row from another host is no drop.
    /// `foldedLast` is the last space of a folded group, whose rows are not
    /// shown: its header carries the line that belongs below them.
    @ViewBuilder
    fileprivate func spaceReordering(
        _ key: String,
        on hostID: UUID,
        among entries: [SpaceOrder.Entry]?,
        drag: SpaceDragState,
        foldedLast: String? = nil,
        onDrop: @escaping ([SpaceOrder.Entry], String) -> Bool
    ) -> some View {
        #if os(tvOS)
        self
        #else
        if let entries {
            modifier(SpaceReordering(key: key, hostID: hostID, entries: entries, drag: drag, foldedLast: foldedLast, onDrop: onDrop))
        } else {
            self
        }
        #endif
    }
}

#if !os(tvOS)
/// Makes a row draggable, takes drops and draws the insertion line (#255)
/// instead of tinting the row the drop goes onto. The payload doubles as
/// the drag's item ID, which the drop session reports to the rows the drag
/// enters; that is what the line is drawn from, not the payload closure,
/// which SwiftUI evaluates once per row and keeps for later drags.
private struct SpaceReordering: ViewModifier {
    let key: String
    let hostID: UUID
    let entries: [SpaceOrder.Entry]
    let drag: SpaceDragState
    let foldedLast: String?
    let onDrop: ([SpaceOrder.Entry], String) -> Bool

    private var host: String { "\(hostID.uuidString)\n" }

    private var line: SpaceOrder.InsertionLine? {
        guard let hover = drag.hover else { return nil }
        return SpaceOrder.insertionLine(entries, dragged: hover.dragged, onto: hover.over)
    }

    func body(content: Content) -> some View {
        let line = line
        let top = line.map { !$0.below && $0.key == key } ?? false
        let bottom = line.map { $0.below && ($0.key == key || $0.key == foldedLast) } ?? false
        content
            .overlay(alignment: .top) { if top { InsertionBar() } }
            .overlay(alignment: .bottom) { if bottom { InsertionBar() } }
            .draggable(String.self, id: \.self, item: "\(host)\(key)")
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(own) else { return }
                _ = onDrop(entries, dragged)
            }
            .dropConfiguration { session in
                let allowed = dragged(in: session).map { SpaceOrder.moved(entries, dragged: $0, onto: key) != nil } ?? false
                return DropConfiguration(operation: allowed ? .move : .forbidden)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active:
                    let hover = dragged(in: session).map { SpaceDragState.Hover(dragged: $0, over: key) }
                    if drag.hover != hover { drag.hover = hover }
                case .exiting:
                    if drag.hover?.over == key { drag.hover = nil }
                case .ended, .dataTransferCompleted:
                    drag.hover = nil
                @unknown default:
                    break
                }
            }
    }

    /// The key of the row `session` drags when it is one of this host's;
    /// `nil` for a drag from elsewhere.
    private func dragged(in session: DropSession) -> String? {
        session.localSession?.draggedItemIDs(for: String.self).first.flatMap(own)
    }

    /// `item` without the host prefix, `nil` when it is another host's.
    private func own(_ item: String) -> String? {
        item.hasPrefix(host) ? String(item.dropFirst(host.count)) : nil
    }
}

private struct InsertionBar: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
    }
}
#endif

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

/// A name group ("Privat" for "Privat/Dorfkino") that folds its spaces.
/// Like a folded section it keeps waiting agents visible.
private struct SpaceGroupRow: View {
    let name: String
    let spaces: Int
    let waiting: Int
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: collapsed ? "folder" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if waiting > 0 {
                    Text("\(waiting) wartet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentState.blocked.color)
                }
                Text("\(spaces)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "Gruppe \(name) aufklappen" : "Gruppe \(name) zuklappen")
        .accessibilityValue(waiting > 0 ? "\(spaces) Spaces, \(waiting) wartet" : "\(spaces) Spaces")
    }
}

/// A space the way herdr's sidebar shows it: name, then the branch, then
/// custom values from plugins or agents. A linked worktree is indented and
/// named after its branch; in a name group the row shows the short name
/// and is indented under the group.
struct SpaceRow: View {
    let workspace: WorkspaceItem
    let nested: Bool
    var grouped = false

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
        .padding(.leading, grouped ? 16 : 0)
    }

    private var title: String {
        if nested { return workspace.branch ?? workspace.worktreeName ?? workspace.label }
        return workspace.name
    }

    /// The branch line; a nested worktree already shows its branch as name.
    private var branchLine: String? {
        nested ? nil : workspace.branch
    }
}

/// An agent the way herdr's sidebar shows it by default: state, space and
/// tab number (only when the space has several tabs), then the agent. A
/// grouped space shows its short name with the group beside it.
private struct AgentRow: View {
    let agent: BoardItem
    let tabNumber: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusDot(state: agent.agentState)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tabNumber.map { "\(agent.workspaceName) · \($0)" } ?? agent.workspaceName)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let group = agent.workspaceGroup {
                        Text(group)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if agent.agentState != .idle {
                        Text(agent.agentState.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(agent.agentState.color)
                    }
                }
                Text(agent.name.map { "\($0) · \(agent.agent)" } ?? agent.agent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    /// "Umbenennen" in the context menu and as a swipe action, for rows and
    /// tab buttons. Without input allowed there is nothing to offer.
    func renameAction(
        available: Bool,
        label: LocalizedStringKey = "Umbenennen …",
        action: @escaping () -> Void
    ) -> some View {
        renameAction(available: available, label: label, action: action) { EmptyView() }
    }

    /// Same, with further entries in the context menu: a view has only one.
    @ViewBuilder
    func renameAction<More: View>(
        available: Bool,
        label: LocalizedStringKey = "Umbenennen …",
        action: @escaping () -> Void,
        @ViewBuilder more: () -> More
    ) -> some View {
        if available {
            self
                .contextMenu {
                    Button(label, systemImage: "pencil", action: action)
                    more()
                }
                #if !os(tvOS)
                .swipeActions(edge: .trailing) {
                    Button(label, systemImage: "pencil", action: action)
                        .tint(.accentColor)
                }
                #endif
        } else {
            self
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
        let spaces = SpaceOrder.arrange(update).map(\.workspace)
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
            if let session = sessionNameOfSocket(socketPath: connection.config.socketPath) {
                Text("Session \(session)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
    #if os(tvOS)
    @State private var pairing = false
    #endif

    var body: some View {
        ContentUnavailableView {
            Label("Keine Hosts", systemImage: "server.rack")
        } description: {
            #if os(tvOS)
            Text("Koppeln Sie dieses Apple TV mit Amiscara Agents auf Ihrem iPhone. Das iPhone gibt ihm Zugang zu Ihren Hosts.")
            #else
            Text("Fügen Sie einen Rechner hinzu, auf dem herdr läuft.")
            #endif
        } actions: {
            #if os(tvOS)
            Button("Mit iPhone koppeln", systemImage: "iphone") { pairing = true }
                .buttonStyle(.borderedProminent)
            #endif
            AddHostButton(editing: $editing)
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                #endif
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $pairing) { TVPairingView() }
        #endif
    }
}

#if os(iOS)
/// Turns the Live Activity of working agents on and off (#224).
private struct LiveActivityToggle: View {
    @Environment(HostStore.self) private var store
    @AppStorage(AgentLiveActivity.enabledKey) private var enabled = true

    var body: some View {
        Toggle("Live-Aktivität", isOn: $enabled)
            .onChange(of: enabled) { AgentLiveActivity.shared.settingChanged(store: store) }
    }
}
#endif
