import Foundation

/// The tab and pane last shown per space (#263), so a space opened again
/// from its row comes back on the tab the user was working in. Kept on this
/// device, also across launches; the demo mode keeps it in memory. A
/// separate file, not part of `HostConfig`: every tab change would
/// otherwise rewrite `hosts.json` and republish the widgets.
@MainActor
final class LastTabs {
    static let shared = LastTabs()

    struct Entry: Codable, Equatable {
        var tab: String
        var pane: String?
    }

    /// "<host UUID>/<workspace id>" to the last shown tab.
    private var entries: [String: Entry]

    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (DemoMode.isOn ? nil : FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/last-tabs.json"))
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    private static func key(host: UUID, workspace: String) -> String { "\(host.uuidString)/\(workspace)" }

    func entry(host: UUID, workspace: String) -> Entry? {
        entries[Self.key(host: host, workspace: workspace)]
    }

    func record(tab: String, pane: String?, host: UUID, workspace: String) {
        let key = Self.key(host: host, workspace: workspace)
        let entry = Entry(tab: tab, pane: pane)
        guard entries[key] != entry else { return }
        entries[key] = entry
        save()
    }

    /// Drops the memory of a removed host.
    func forget(host: UUID) {
        let prefix = host.uuidString + "/"
        let before = entries.count
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        if entries.count != before { save() }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost entry only means the space opens on herdr's active tab.
        }
    }
}
