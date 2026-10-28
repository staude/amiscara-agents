import Foundation

/// The last screen of every pane seen (#276), so a pane keeps showing it
/// while its host is out of reach: in memory for the app's lifetime and in
/// the cache directory across launches (`PaneCacheFiles`). Also the pane
/// open last, which the app opens again on launch.
@MainActor
final class PaneCache {
    static let shared = PaneCache()

    struct Entry {
        var content: PaneContent
        var title: String?
        /// When the screen last changed.
        var date: Date
    }

    /// The space and pane shown last, for the next launch.
    struct LastOpen: Codable, Equatable {
        var host: UUID
        var workspace: String
        var pane: String?
        /// The space's name, for its title before the host knows its spaces.
        var spaceName: String
    }

    /// Rows kept per pane; more history is not worth the space.
    static let maxLines = 500
    /// Changes of one pane within this pause go to disk once.
    private static let writeDelay: Duration = .seconds(5)
    private static let lastOpenKey = "lastOpenPane"

    private struct Key: Hashable {
        let host: UUID
        let pane: String
    }

    private var entries: [Key: Entry] = [:]
    /// Titles seen, also before the pane's first screen.
    private var titles: [Key: String] = [:]
    /// Panes looked up on disk already. A pane not found is looked up
    /// again after `retryMisses()`: a locked device cannot read the files.
    private var loaded: Set<Key> = []
    private var missed: Set<Key> = []
    /// Removed hosts: a screen still on its way is not kept.
    private var forgotten: Set<UUID> = []
    /// Panes with a write planned.
    private var pending: Set<Key> = []
    private let files: PaneCacheFiles
    /// The files are written off the main actor, one after the other.
    private let disk = DispatchQueue(label: "net.staude.amiscara.agents.pane-cache")
    /// `nil` keeps `lastOpen` in memory only.
    private let defaults: UserDefaults?

    var lastOpen: LastOpen? {
        didSet {
            guard lastOpen != oldValue, let defaults else { return }
            if let lastOpen, let data = try? JSONEncoder().encode(lastOpen) {
                defaults.set(data, forKey: Self.lastOpenKey)
            } else {
                defaults.removeObject(forKey: Self.lastOpenKey)
            }
        }
    }

    /// The demo mode keeps nothing on the device.
    private convenience init() {
        self.init(
            directory: DemoMode.isOn ? nil : FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "AmiscaraAgents/panes"),
            defaults: DemoMode.isOn ? nil : .standard
        )
    }

    /// For `scripts/pane-cache-ffi-test.sh`.
    init(directory: URL?, defaults: UserDefaults?) {
        files = PaneCacheFiles(directory: directory)
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.lastOpenKey) {
            lastOpen = try? JSONDecoder().decode(LastOpen.self, from: data)
        }
    }

    /// Keeps a new screen of the pane, the last `maxLines` rows of it.
    func record(_ content: PaneContent, host: UUID, pane: String) {
        guard !forgotten.contains(host) else { return }
        let key = Key(host: host, pane: pane)
        // The title kept on disk, which this write would drop otherwise.
        _ = entry(host: host, pane: pane)
        let kept = PaneContent(
            paneId: content.paneId,
            lines: Array(content.lines.suffix(Self.maxLines)),
            truncated: false,
            historyLines: 0,
            // Nothing to answer while the host is out of reach.
            question: nil
        )
        entries[key] = Entry(content: kept, title: titles[key] ?? entries[key]?.title, date: .now)
        missed.remove(key)
        scheduleWrite(key)
    }

    func setTitle(_ title: String, host: UUID, pane: String) {
        let key = Key(host: host, pane: pane)
        guard titles[key] != title else { return }
        titles[key] = title
        if entries[key] != nil, entries[key]?.title != title {
            entries[key]?.title = title
            scheduleWrite(key)
        }
    }

    /// The last screen of the pane, from memory or else from disk.
    func entry(host: UUID, pane: String) -> Entry? {
        let key = Key(host: host, pane: pane)
        if !loaded.contains(key) {
            loaded.insert(key)
            if let file = files.read(host: host, pane: pane),
               let content = paneContentFromJson(json: file.json) {
                entries[key] = Entry(content: content, title: titles[key] ?? file.title, date: file.date)
            } else {
                missed.insert(key)
            }
        }
        return entries[key]
    }

    /// Looks up the panes not found on disk again, e.g. once the device
    /// is unlocked.
    func retryMisses() {
        loaded.subtract(missed)
        missed = []
    }

    /// Writes the planned screens now and waits for the disk, e.g. before
    /// the app is suspended or quits.
    func flush() {
        for key in pending { write(key) }
        disk.sync {}
    }

    /// Drops what is kept of a removed host.
    func forget(host: UUID) {
        entries = entries.filter { $0.key.host != host }
        titles = titles.filter { $0.key.host != host }
        loaded = loaded.filter { $0.host != host }
        missed = missed.filter { $0.host != host }
        forgotten.insert(host)
        pending = pending.filter { $0.host != host }
        let files = files
        // After the writes already on their way.
        disk.async { files.forget(host: host) }
        if lastOpen?.host == host { lastOpen = nil }
    }

    private func scheduleWrite(_ key: Key) {
        guard pending.insert(key).inserted else { return }
        Task {
            try? await Task.sleep(for: Self.writeDelay)
            write(key)
        }
    }

    private func write(_ key: Key) {
        guard pending.remove(key) != nil, let entry = entries[key] else { return }
        let json = paneContentJson(content: entry.content)
        let (files, title, date) = (files, entry.title, entry.date)
        disk.async {
            files.write(json, title: title, host: key.host, pane: key.pane, date: date)
        }
    }
}
