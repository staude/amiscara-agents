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
    var loadError: String?

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
        connection.onUpdate = { [weak self] connection, update in
            guard let self else { return }
            self.notifier.notify(update.attention, on: connection.config)
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
        connection(for: config.id)?.apply(config)
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
        connections.remove(at: index)
        save()
    }

    /// Reconnects hosts that are not live right away, e.g. when the app
    /// returns to the foreground and the driver still waits out a backoff.
    func reconnectStale() {
        for connection in connections where !connection.isLive && !connection.needsHostKeyDecision {
            connection.start()
        }
    }

    func trustHostKey(_ key: String, for id: UUID) {
        guard var config = connection(for: id)?.config else { return }
        config.pinnedHostKey = key
        update(config)
    }

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
