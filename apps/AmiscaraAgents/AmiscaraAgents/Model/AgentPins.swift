import Foundation
import Observation

/// Agents pinned to the top of the overview, the host dashboard and the
/// sidebar (#334). Kept in iCloud's key-value store, so Mac, iPhone and
/// iPad show the same pins. Host entries differ per device, so a pin names
/// its host like the Handoff does: SSH host key fingerprint, herdr session
/// and user, then the pane. A host without a known key keeps its pins on
/// this device only. The demo mode keeps them in memory; the Apple TV has
/// none.
@MainActor
@Observable
final class AgentPins {
    static let shared = AgentPins()

    private static let storeKey = "agentPins"

    /// "<host>|<session>|<user>|<pane id>" per pinned agent.
    private(set) var keys: Set<String> = []

    #if !os(tvOS)
    @ObservationIgnored private var observer: NSObjectProtocol?

    private var store: NSUbiquitousKeyValueStore? {
        DemoMode.isOn ? nil : NSUbiquitousKeyValueStore.default
    }
    #endif

    private init() {
        #if !os(tvOS)
        guard let store else { return }
        store.synchronize()
        keys = Self.read(store)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let store = self.store else { return }
                let keys = Self.read(store)
                if keys != self.keys { self.keys = keys }
            }
        }
        #endif
    }

    #if !os(tvOS)
    /// A missing value or one of another type counts as no pins.
    private static func read(_ store: NSUbiquitousKeyValueStore) -> Set<String> {
        Set((store.array(forKey: storeKey) as? [String]) ?? [])
    }
    #endif

    /// The part of a pin's key that names the host and its herdr server.
    static func prefix(of connection: HostConnection) -> String {
        let host = PaneHandoff.hostKey(of: connection) ?? "local-\(connection.config.id.uuidString)"
        return "\(host)|\(PaneHandoff.session(of: connection))|\(PaneHandoff.user(of: connection))|"
    }

    func isPinned(_ paneID: String, on connection: HostConnection) -> Bool {
        #if os(tvOS)
        return false
        #else
        return keys.contains(Self.prefix(of: connection) + paneID)
        #endif
    }

    func toggle(_ paneID: String, on connection: HostConnection) {
        #if !os(tvOS)
        let key = Self.prefix(of: connection) + paneID
        var keys = keys
        if keys.remove(key) == nil { keys.insert(key) }
        save(keys)
        #endif
    }

    /// The pane ids pinned on this host.
    func pinnedPanes(on connection: HostConnection) -> Set<String> {
        #if os(tvOS)
        return []
        #else
        let prefix = Self.prefix(of: connection)
        return Set(keys.lazy.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        #endif
    }

    /// Drops the pins of panes the host no longer has. Only for a host
    /// this device sees connected, so a dropped link keeps the pins.
    func prune(on connection: HostConnection, keeping panes: Set<String>) {
        #if !os(tvOS)
        let prefix = Self.prefix(of: connection)
        let kept = keys.filter { key in
            !key.hasPrefix(prefix) || panes.contains(String(key.dropFirst(prefix.count)))
        }
        if kept != keys { save(kept) }
        #endif
    }

    #if !os(tvOS)
    private func save(_ keys: Set<String>) {
        self.keys = keys
        guard let store else { return }
        store.set(keys.sorted(), forKey: Self.storeKey)
    }
    #endif
}
