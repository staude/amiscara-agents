import CryptoKit
import Foundation
import Observation

/// Tabs put away (#333): hidden from the tab bar of their space while they
/// keep running on the host. An agent that starts waiting brings its tab
/// back. Synced through iCloud's key-value store, so the Mac, iPhone and
/// iPad hide the same tabs; a host is known everywhere by its SSH host key
/// (`HostConnection.settledHost`). The demo mode and the Apple TV keep
/// the state in memory only.
@MainActor
@Observable
final class SettledTabs {
    static let shared = SettledTabs(backing: defaultBacking)

    private static var defaultBacking: NSUbiquitousKeyValueStore? {
        #if os(tvOS)
        nil
        #else
        DemoMode.isOn ? nil : .default
        #endif
    }

    static let keyPrefix = "settledTabs-"

    /// Storage key to the tab IDs put away on that host.
    private var settled: [String: Set<String>] = [:]

    @ObservationIgnored private let backing: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(backing: NSUbiquitousKeyValueStore?) {
        self.backing = backing
        guard let backing else { return }
        for (key, value) in backing.dictionaryRepresentation where key.hasPrefix(Self.keyPrefix) {
            if let tabs = value as? [String], !tabs.isEmpty { settled[key] = Set(tabs) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: backing,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.reload(keys) }
        }
        backing.synchronize()
    }

    /// The key a host's tabs are stored under. The key-value store takes
    /// at most 64 bytes per key, a host string can be longer.
    static func storageKey(host: String) -> String {
        let digest = SHA256.hash(data: Data(host.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hex.prefix(32)
    }

    func contains(tab: String, host: String) -> Bool {
        settled[Self.storageKey(host: host)]?.contains(tab) ?? false
    }

    func tabs(host: String) -> Set<String> {
        settled[Self.storageKey(host: host)] ?? []
    }

    func settle(tab: String, host: String) {
        change(host: host) { $0.insert(tab) }
    }

    func unsettle(tab: String, host: String) {
        change(host: host) { $0.remove(tab) }
    }

    /// Brings back the given tabs, e.g. all of one space.
    func unsettleAll(host: String, tabs: Set<String>) {
        change(host: host) { $0.subtract(tabs) }
    }

    /// Forgets put away tabs the host no longer has, so a new tab that
    /// gets an old ID shows.
    func prune(host: String, keeping tabs: Set<String>) {
        change(host: host) { $0.formIntersection(tabs) }
    }

    /// After a live update: a tab whose agent waits comes back and stays.
    /// With `complete`, the update lists every tab of the host, and tabs
    /// it no longer has are forgotten.
    func revive(host: String, tabs: [(id: String, waiting: Bool)], complete: Bool) {
        change(host: host) { settled in
            for tab in tabs where tab.waiting { settled.remove(tab.id) }
            if complete { settled.formIntersection(tabs.map(\.id)) }
        }
    }

    private func change(host: String, _ edit: (inout Set<String>) -> Void) {
        let key = Self.storageKey(host: host)
        let before = settled[key] ?? []
        var after = before
        edit(&after)
        guard after != before else { return }
        if after.isEmpty {
            settled[key] = nil
            backing?.removeObject(forKey: key)
        } else {
            settled[key] = after
            backing?.set(after.sorted(), forKey: key)
        }
    }

    /// Another device changed these keys.
    private func reload(_ keys: [String]) {
        guard let backing else { return }
        for key in keys where key.hasPrefix(Self.keyPrefix) {
            let tabs = Set(backing.array(forKey: key) as? [String] ?? [])
            if settled[key] ?? [] != tabs { settled[key] = tabs.isEmpty ? nil : tabs }
        }
    }
}
