import Foundation
import Observation

/// All configured hosts, persisted as JSON in Application Support.
@MainActor
@Observable
final class HostStore {
    private(set) var connections: [HostConnection] = []
    let notifier = Notifier()
    @ObservationIgnored let widgets = WidgetPublisher()
    #if os(macOS)
    /// Events of the local host for pushes through iCloud (#119).
    let cloudPush = CloudPushSender()
    #endif
    #if !os(tvOS)
    /// The agents as last seen and as Siri last learned them by name
    /// (#275), and the pause between two updates; see `updateShortcutAgents(_:)`.
    @ObservationIgnored private var shortcutAgentsSeen: Set<String> = []
    @ObservationIgnored private var shortcutAgentsSent: Set<String> = []
    @ObservationIgnored private var shortcutPause: Task<Void, Never>?
    #endif
    var loadError: String?
    /// The boards the Mac apps leave in iCloud for this device's hosts
    /// (#156), as last fetched by `widgets`.
    var cloudBoards: [CloudBoard] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AmiscaraAgents/hosts.json")
    }()

    init() {
        if let socket = DemoMode.socket {
            // Screenshots (#199): only the demo session, nothing goes out.
            connections = [connect(DemoMode.host(socket: socket))]
            connections.forEach { $0.start() }
            return
        }
        load()
        if connections.isEmpty, Platform.hasLocalSocket,
           FileManager.default.fileExists(atPath: Platform.localSocketPath) {
            connections = [connect(.local())]
            save()
        }
        connections.forEach { $0.start() }
        notifier.answer = { [weak self] host, pane, key in
            await self?.answer(key, to: pane, on: host) ?? false
        }
        #if os(iOS)
        WatchBridge.shared.answer = { [weak self] host, pane, key in
            await self?.answerError(key, to: pane, on: host) ?? String(localized: "Die App ist nicht bereit.")
        }
        WatchBridge.shared.prompt = { [weak self] host, pane, text in
            await self?.promptError(text, to: pane, on: host) ?? String(localized: "Die App ist nicht bereit.")
        }
        // Answer buttons of the Live Activity (#224).
        AgentActivityBridge.answer = { [weak self] host, pane, key in
            await self?.answer(key, to: pane, on: host) ?? false
        }
        // A new board from the Mac while in the background.
        WidgetPublisher.backgroundRefresh = { [weak self] in
            guard let self, !DemoMode.isOn else { return }
            await self.widgets.refreshFromCloud(self)
        }
        #endif
        notifier.hostForKey = { [weak self] key in
            self?.connections.first { CloudPush.hostKey(forPublicKey: $0.config.pinnedHostKey) == key }?.id
        }
        widgets.start(self)
        widgets.publish(self)
        #if os(macOS)
        startCloudCommands()
        #endif
    }

    /// A connection wired to notifications and the badge.
    private func connect(_ config: HostConfig) -> HostConnection {
        let connection = HostConnection(config: config)
        connection.usage.onChange = { [weak self] in
            guard let self, !DemoMode.isOn || DemoMode.widgets else { return }
            self.widgets.publish(self)
        }
        connection.onUpdate = { [weak self] connection, update in
            guard let self else { return }
            self.notifier.notify(update.attention, on: connection.config) { [weak connection] paneID in
                await connection?.choiceQuestion(paneID: paneID)
            }
            self.notifier.updateBadge(waiting: self.waitingAgents
                .filter(\.connection.config.notificationsOn)
                .count)
            guard !DemoMode.isOn || DemoMode.widgets else { return }
            self.widgets.publish(self)
            guard !DemoMode.isOn else { return }
            #if os(macOS)
            if let (key, name) = self.cloudHost(of: connection) {
                self.cloudPush.send(update.attention, hostKey: key, hostName: name) { [weak connection] paneID in
                    await connection?.screenExcerpt(paneID: paneID, lines: CloudPush.excerptLines)
                }
                self.cloudPush.sendBoard(update.board, live: connection.isLive, hostKey: key, hostName: name)
            }
            #endif
        }
        return connection
    }

    #if os(macOS)
    /// Key fingerprint and name under which a host's events go to iCloud,
    /// or `nil` when they do not: this Mac by its own host key, SSH hosts by
    /// their pinned key (#125).
    func cloudHost(of connection: HostConnection) -> (key: String, name: String)? {
        guard connection.config.notificationsOn else { return nil }
        switch connection.config.kind {
        case .local:
            return cloudPush.hostKey.map { ($0, Host.current().localizedName ?? connection.config.name) }
        case .ssh:
            guard cloudPush.includeSSHHosts,
                  let key = CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
            else { return nil }
            return (key, connection.config.name)
        }
    }
    #endif

    /// An answer key from a notification button. Launched for it in the
    /// background, the app first has to reconnect; iOS gives it some
    /// seconds for that.
    func answer(_ key: String, to paneID: String, on hostID: UUID) async -> Bool {
        await answerError(key, to: paneID, on: hostID) == nil
    }

    /// Like `answer`, with the reason when the key did not go out, e.g.
    /// for the Watch (#157).
    func answerError(_ key: String, to paneID: String, on hostID: UUID) async -> String? {
        await sendError(on: hostID) { try await $0.send(keys: [key], to: paneID) }
    }

    /// Sends `text` as a prompt to the agent in `paneID`, for the Watch
    /// (#159); `nil` when it went out, else why not.
    func promptError(_ text: String, to paneID: String, on hostID: UUID) async -> String? {
        await sendError(on: hostID) { try await $0.submit(text, to: paneID, isAgent: true) }
    }

    /// Runs `send` on the host's connection, reconnecting first: launched
    /// in the background, the app has some seconds for that.
    private func sendError(on hostID: UUID, _ send: (HostConnection) async throws -> Void) async -> String? {
        guard let connection = connection(for: hostID) else {
            return String(localized: "Diesen Host gibt es auf dem iPhone nicht mehr.")
        }
        if !connection.isLive, !connection.needsHostKeyDecision {
            connection.start()
        }
        for _ in 0..<60 where !connection.isLive {
            try? await Task.sleep(for: .milliseconds(250))
        }
        do {
            try await send(connection)
            return nil
        } catch {
            return inputErrorMessage(error)
        }
    }

    /// Agents waiting for an answer, over all hosts in sidebar order.
    var waitingAgents: [(connection: HostConnection, agent: BoardItem)] {
        connections.flatMap { connection in
            (connection.update?.board ?? [])
                .filter { $0.agentState == .blocked }
                .map { (connection: connection, agent: $0) }
        }
    }

    /// The agents of all hosts for the overview (#274); hosts without a
    /// connection show their last known state.
    var overview: AgentOverview {
        AgentOverview(
            hosts: connections.map { connection in
                AgentOverview.Host(
                    id: connection.id,
                    name: connection.config.name,
                    live: connection.isLive,
                    liveAt: connection.liveAt,
                    hostKey: CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey),
                    agents: (connection.update?.board ?? []).map(WidgetSnapshot.Agent.init)
                )
            },
            boards: cloudBoards
        )
    }

    /// Open requests hidden on this device with "Ignorieren", by `key`.
    var ignoredOpenRequests: Set<String> = []

    /// Pages agents on the hosts want opened (#247), over all hosts in
    /// sidebar order, without those ignored here. A request leaves once any
    /// device opened it or its time ran out.
    var openRequests: [PendingOpen] {
        connections.flatMap { connection in
            (connection.update?.openRequests ?? []).map { PendingOpen(connection: connection, request: $0) }
        }
        .filter { !ignoredOpenRequests.contains($0.key) }
    }

    /// Folders agents on the hosts want opened in VS Code (#288), like
    /// `openRequests`; hidden with the same "Ignorieren".
    var editorRequests: [PendingEditor] {
        connections.flatMap { connection in
            (connection.update?.editorRequests ?? []).map { PendingEditor(connection: connection, request: $0) }
        }
        .filter { !ignoredOpenRequests.contains($0.key) }
    }

    func connection(for id: UUID?) -> HostConnection? {
        connections.first { $0.id == id }
    }

    func add(_ config: HostConfig) {
        let connection = connect(config)
        connections.append(connection)
        save()
        connection.start()
    }

    func update(_ config: HostConfig) {
        guard let connection = connection(for: config.id) else { return }
        // The sidebar changes the order while an editor holds an older copy.
        var config = config
        config.spaceSort = connection.config.spaceSort
        config.spaceOrder = connection.config.spaceOrder
        connection.apply(config)
        save()
    }

    func setSpaceSort(_ mode: SpaceSortMode, order: [String]?, for id: UUID) {
        guard let connection = connection(for: id) else { return }
        connection.setSpaceSort(mode, order: order)
        save()
    }

    func remove(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections[index]
        #if os(macOS)
        if let (key, _) = cloudHost(of: connection) {
            cloudPush.removeBoard(hostKey: key)
        }
        #endif
        connection.stop()
        KeyStore.delete(for: id)
        #if !os(tvOS)
        SecretStore.deleteAll(for: id)
        #endif
        PromptHistory.shared.forget(host: id)
        LastTabs.shared.forget(host: id)
        PaneVisits.shared.forget(host: id)
        UsageStore.forget(host: id)
        PaneCache.shared.forget(host: id)
        connections.remove(at: index)
        save()
    }

    /// Reconnects hosts that are not live right away, e.g. when the app
    /// returns to the foreground and the driver still waits out a backoff.
    /// Sessions keep their state, so changes in the meantime notify (#264).
    func reconnectStale() {
        for connection in connections where !connection.isLive && !connection.needsHostKeyDecision {
            connection.reconnect()
        }
    }

    /// Reconnects every remote host, live or not: after the device slept
    /// or long in the background its SSH link may be dead while it still
    /// counts as live until the keepalives give up a minute later (#258).
    /// The session keeps its state and panes follow the new connection, so
    /// agents that finished meanwhile still notify (#264). Other hosts
    /// reconnect as in `reconnectStale()`.
    func reconnectRemote() {
        for connection in connections
        where (connection.config.kind == .ssh || !connection.isLive) && !connection.needsHostKeyDecision {
            connection.reconnect()
        }
    }

    func trustHostKey(_ key: String, for id: UUID) {
        guard var config = connection(for: id)?.config else { return }
        config.pinnedHostKey = key
        update(config)
    }

    #if !os(tvOS)
    /// Tells Siri the agents again when one came, went or was renamed, so
    /// it understands their names in the phrases (#275). Takes the widgets'
    /// snapshot, which also holds the Mac's boards and loses removed hosts.
    /// At most once a minute: Siri then asks for the agents, and that
    /// reconnects hosts that are not live.
    func updateShortcutAgents(_ snapshot: WidgetSnapshot) {
        // Name and space are what Siri understands; tabs do not count.
        shortcutAgentsSeen = Set(snapshot.hosts.flatMap { host in
            host.agents.map { agent in
                let space = agent.place.components(separatedBy: " · ").first ?? agent.place
                return "\(host.id)/\(agent.paneID)|\(agent.name)|\(space)"
            }
        })
        guard shortcutPause == nil else { return }
        sendShortcutAgents()
    }

    /// Sends the agents seen when they changed, then pauses a minute and
    /// sends what changed meanwhile.
    private func sendShortcutAgents() {
        guard shortcutAgentsSeen != shortcutAgentsSent else {
            shortcutPause = nil
            return
        }
        shortcutAgentsSent = shortcutAgentsSeen
        HerdrShortcuts.updateAppShortcutParameters()
        shortcutPause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.sendShortcutAgents()
        }
    }
    #endif

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let configs = try JSONDecoder().decode([HostConfig].self, from: data)
            connections = configs.map(connect)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard !DemoMode.isOn else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(connections.map(\.config)).write(to: fileURL, options: .atomic)
        } catch {
            loadError = error.localizedDescription
        }
        // Added, removed or renamed hosts show in the widgets at once.
        widgets.publish(self)
    }
}

/// A folder an agent on a host wants opened in VS Code, with its host.
struct PendingEditor: Identifiable {
    let connection: HostConnection
    let request: EditorRequest

    /// As `PendingOpen.key`, apart from page requests of the same pane.
    var key: String { "editor|\(connection.id)|\(request.paneId)|\(request.requestId)" }
    var id: String { key }
}

/// A page an agent on a host wants opened, with its host.
struct PendingOpen: Identifiable {
    let connection: HostConnection
    let request: OpenRequest

    /// Unique over hosts and panes; a new request of the pane gets a new one.
    var key: String { "\(connection.id)|\(request.paneId)|\(request.requestId)" }
    var id: String { key }
}
