import Foundation
import Observation

/// All configured hosts, persisted as JSON in Application Support.
@MainActor
@Observable
final class HostStore {
    private(set) var connections: [HostConnection] = []
    var loadError: String?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "HerdrRemote/hosts.json")
    }()

    init() {
        load()
        if connections.isEmpty, FileManager.default.fileExists(atPath: Self.localSocketPath) {
            connections = [HostConnection(config: .local())]
            save()
        }
        connections.forEach { $0.start() }
    }

    static var localSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/herdr/herdr.sock").path
    }

    func connection(for id: UUID?) -> HostConnection? {
        connections.first { $0.id == id }
    }

    func add(_ config: HostConfig) {
        let connection = HostConnection(config: config)
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

    func trustHostKey(_ key: String, for id: UUID) {
        guard var config = connection(for: id)?.config else { return }
        config.pinnedHostKey = key
        update(config)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let configs = try JSONDecoder().decode([HostConfig].self, from: data)
            connections = configs.map(HostConnection.init(config:))
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
