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
        notifier.hostForKey = { [weak self] key in
            self?.connections.first { CloudPush.hostKey(forPublicKey: $0.config.pinnedHostKey) == key }?.id
        }
        widgets.start(self)
        widgets.publish(self)
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
            self.widgets.publish(self)
            #if os(macOS)
            if connection.config.notificationsOn {
                switch connection.config.kind {
                case .local:
                    self.cloudPush.send(update.attention, hostName: Host.current().localizedName ?? connection.config.name)
                case .ssh:
                    // Devices find the host by its pinned key (#125).
                    if self.cloudPush.includeSSHHosts,
                       let key = CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey) {
                        self.cloudPush.send(update.attention, hostKey: key, hostName: connection.config.name)
                    }
                }
            }
            #endif
        }
        return connection
    }

    /// An answer key from a notification button. Launched for it in the
    /// background, the app first has to reconnect; iOS gives it some
    /// seconds for that.
    func answer(_ key: String, to paneID: String, on hostID: UUID) async -> Bool {
        guard let connection = connection(for: hostID) else { return false }
        if !connection.isLive, !connection.needsHostKeyDecision {
            connection.start()
        }
        for _ in 0..<60 where !connection.isLive {
            try? await Task.sleep(for: .milliseconds(250))
        }
        do {
            try await connection.send(keys: [key], to: paneID)
            return true
        } catch {
            return false
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
