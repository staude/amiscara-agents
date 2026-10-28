import CryptoKit
import Foundation

/// The files behind `PaneCache` (#276): the last screen of each pane as
/// JSON in the cache directory, one file per pane, so it can be read again
/// after a restart while the host is out of reach. Kept to the newest
/// `maxFiles` panes and `maxAge`; the system may also empty the directory.
/// No app types, so `scripts/pane-cache-test.sh` builds it alone.
struct PaneCacheFiles: Sendable {
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxFiles = 40

    private struct Envelope: Codable {
        var json: String
        var title: String?
        var date: Date
    }

    /// `nil` (the demo mode) writes and reads nothing.
    private let directory: URL?
    private let now: @Sendable () -> Date

    init(directory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// The pane ID goes into the name hashed: it may hold any characters.
    private func fileURL(host: UUID, pane: String) -> URL? {
        let hash = SHA256.hash(data: Data(pane.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appending(path: "\(host.uuidString)-\(hash).json")
    }

    func write(_ json: String, title: String?, host: UUID, pane: String, date: Date) {
        guard let directory, let url = fileURL(host: host, pane: pane) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(json: json, title: title, date: date))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            // The pruning goes by this date and needs to read no file.
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch {
            // A lost screen only means the pane shows nothing while offline.
        }
        prune()
    }

    /// `nil` for a missing, broken or too old file.
    func read(host: UUID, pane: String) -> (json: String, title: String?, date: Date)? {
        guard let url = fileURL(host: host, pane: pane),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              now().timeIntervalSince(envelope.date) <= Self.maxAge
        else { return nil }
        return (envelope.json, envelope.title, envelope.date)
    }

    /// Drops the screens of a removed host.
    func forget(host: UUID) {
        let prefix = host.uuidString + "-"
        for (url, _) in files() where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Screens older than `maxAge`, then the oldest beyond `maxFiles`.
    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var kept: [(url: URL, date: Date)] = []
        for file in files() {
            if file.date < cutoff {
                try? FileManager.default.removeItem(at: file.url)
            } else {
                kept.append(file)
            }
        }
        for file in kept.sorted(by: { $0.date > $1.date }).dropFirst(Self.maxFiles) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func files() -> [(url: URL, date: Date)] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}
