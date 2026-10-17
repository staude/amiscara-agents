import Foundation
import Observation

/// All configured hosts, persisted as JSON in Application Support.
@MainActor
@Observable
final class HostStore {
    private(set) var connections: [HostConnection] = []
    let notifier = Notifier()
    var loadError: String?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "HerdrRemote/hosts.json")
    }()

    init() {
        load()
        if connections.isEmpty, Platform.hasLocalSocket,
           FileManager.default.fileExists(atPath: Platform.localSocketPath) {
            connections = [connect(.local())]
            save()
        }
        connections.forEach { $0.start() }
    }

    /// A connection wired to notifications and the badge.
    private func connect(_ config: HostConfig) -> HostConnection {
        let connection = HostConnection(config: config)
        connection.onUpdate = { [weak self] connection, update in
            guard let self else { return }
            self.notifier.notify(update.attention, on: connection.config)
            self.notifier.updateBadge(waiting: self.connections
                .filter(\.config.notificationsOn)
                .flatMap { $0.update?.board ?? [] }
                .filter { $0.agentState == .blocked }
                .count)
        }
        return connection
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
        connections[index].stop()
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
    }
}
