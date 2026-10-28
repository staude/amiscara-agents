#if os(iOS) || os(macOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Indexes the spaces and agents of every host in Spotlight (#308), so
/// typing a space or agent name in the system search opens it, even with
/// the app's window closed. tvOS and the Watch compile the same sources
/// without this file (no CoreSpotlight there).
@MainActor
final class SpotlightIndex {
    static let shared = SpotlightIndex()

    static let enabledKey = "spotlightIndex"

    /// On unless turned off in the settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Entries as last computed per host, including hosts not written yet.
    private var pending: [UUID: [SpotlightEntry]] = [:]
    /// Entries as last written per host, to skip a write without a change.
    private var written: [UUID: [SpotlightEntry]] = [:]
    /// A host's spaces as last seen live, kept while it is unreachable and
    /// has only agents from iCloud (Entscheidung 3): iCloud boards carry no
    /// space information, so without this a host that drops its connection
    /// would lose its space entries even though nothing closed.
    private var lastSpaces: [UUID: [SpotlightEntries.Space]] = [:]
    /// Debounces writes (Entscheidung 2 des Plans): at most every 30s,
    /// because agents change state often.
    private var pauseTask: Task<Void, Never>?
    /// The batch of per-host writes currently running; cancelled when the
    /// setting turns off so a write in flight cannot land after `clearAll()`
    /// already cleared Spotlight.
    private var writeTask: Task<Void, Never>?
    private static let pause: TimeInterval = 30

    private static let indexedHostsKey = "spotlightHosts"

    /// Host IDs this index has written entries for, kept past a relaunch so
    /// `start(hostIDs:)` can clean up hosts removed meanwhile.
    private var indexedHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.indexedHostsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.indexedHostsKey) }
    }

    /// Recomputes every host's entries and writes what changed, debounced.
    /// A host the app cannot reach right now and that has no agents from
    /// iCloud keeps its last entries (Entscheidung 3): only a removed host,
    /// a closed space or a finished agent drops out.
    func update(store: HostStore, snapshot: WidgetSnapshot) {
        guard !DemoMode.isOn, Self.isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        for connection in store.connections {
            let hostID = connection.id
            let hostName = connection.config.name
            let agents = snapshot.hosts.first { $0.id == hostID }?.agents ?? []
            if let update = connection.update {
                let spaces = update.workspaces.map {
                    SpotlightEntries.Space(workspaceID: $0.workspaceId, name: $0.name, label: $0.label, branch: $0.branch)
                }
                lastSpaces[hostID] = spaces
                pending[hostID] = SpotlightEntries.entries(hostID: hostID, hostName: hostName, spaces: spaces, agents: agents)
            } else if !agents.isEmpty {
                pending[hostID] = SpotlightEntries.entries(hostID: hostID, hostName: hostName, spaces: lastSpaces[hostID] ?? [], agents: agents)
            }
        }
        guard pauseTask == nil else { return }
        writeChanged()
    }

    /// Stops indexing hosts that are not in `hostIDs` any more (deleted
    /// while the app was closed); off, drops everything.
    func start(hostIDs: [UUID]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let keep = Set(hostIDs.map(\.uuidString))
        let stale = indexedHosts.subtracting(keep)
        if !stale.isEmpty {
            indexedHosts.subtract(stale)
            Task { try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: Array(stale)) }
        }
        if !Self.isEnabled {
            clearAll()
        }
    }

    /// A removed host loses its entries at once.
    func remove(host id: UUID) {
        let key = id.uuidString
        pending[id] = nil
        written[id] = nil
        lastSpaces[id] = nil
        indexedHosts.remove(key)
        Task { try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [key]) }
    }

    /// Turning the setting off clears Spotlight at once. Turning it on asks
    /// the store to publish again, which recomputes `pending` from the live
    /// connections and, with no pause running, writes it right away.
    func settingChanged(store: HostStore) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        pauseTask?.cancel()
        pauseTask = nil
        if Self.isEnabled {
            store.widgets.publish(store, force: true)
        } else {
            clearAll()
        }
    }

    private func clearAll() {
        writeTask?.cancel()
        writeTask = nil
        pending = [:]
        written = [:]
        lastSpaces = [:]
        indexedHosts = []
        Task { try? await CSSearchableIndex.default().deleteAllSearchableItems() }
    }

    /// Writes every host whose entries changed since the last write, one
    /// after another, then schedules the next check after the pause.
    private func writeChanged() {
        let changed = pending.filter { written[$0.key] != $0.value }
        guard !changed.isEmpty else {
            pauseTask = nil
            return
        }
        writeTask = Task { [weak self] in
            guard let self else { return }
            for (hostID, entries) in changed {
                guard !Task.isCancelled else { return }
                await self.write(hostID: hostID, entries: entries)
            }
        }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            self?.pauseTask = nil
            self?.writeChanged()
        }
    }

    /// Replaces one host's items; a failure, or a cancelled setting-off
    /// in between, leaves `written` as is, so the next write tries again.
    private func write(hostID: UUID, entries: [SpotlightEntry]) async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [hostID.uuidString])
            let items = entries.map { entry in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = entry.title
                attributes.contentDescription = entry.detail
                attributes.keywords = entry.keywords
                return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: hostID.uuidString, attributeSet: attributes)
            }
            try await index.indexSearchableItems(items)
            guard !Task.isCancelled else { return }
            written[hostID] = entries
            indexedHosts.insert(hostID.uuidString)
        } catch {
            // Tried again at the next write.
        }
    }
}
#endif
