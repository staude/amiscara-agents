import Foundation
import Observation

/// What the chains this device ran did (#300): sent, failed or skipped,
/// the newest first, per host. Kept on this device only, outside backups;
/// the demo mode keeps them in memory. Another device's runs show in its
/// own log.
@MainActor
@Observable
final class ChainLog {
    static let shared = ChainLog()

    /// Entries kept per host.
    static let limit = 50

    struct Entry: Codable, Hashable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case sent, failed, skipped
        }

        var chainID: String
        /// The agent whose change fired the chain and the one it prompted.
        var trigger: String
        var target: String
        var text: String
        var outcome: Outcome
        var reason: String?
        var at: Date
    }

    private var stored: [String: [Entry]]

    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (DemoMode.isOn ? nil : FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/chain-log.json"))
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            stored = decoded
        } else {
            stored = [:]
        }
    }

    func entries(host: UUID) -> [Entry] { stored[host.uuidString] ?? [] }

    /// Adds `entries`, oldest first as they happened, in front of the host's
    /// log and keeps the newest `limit`.
    func record(_ entries: [Entry], host: UUID) {
        guard !entries.isEmpty else { return }
        let key = host.uuidString
        stored[key] = Array((entries.reversed() + (stored[key] ?? [])).prefix(Self.limit))
        save()
    }

    func clear(host: UUID) {
        guard stored.removeValue(forKey: host.uuidString) != nil else { return }
        save()
    }

    /// Drops the log of a removed host.
    func forget(host: UUID) { clear(host: host) }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic, .completeFileProtection])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // A lost log entry is not worth an error.
        }
    }
}
