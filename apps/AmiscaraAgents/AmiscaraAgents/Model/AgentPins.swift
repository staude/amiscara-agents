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

    /// The Mac's own host key fingerprint, read from disk once it is there.
    private static var localHostKey: String?

    /// The part of a pin's key that names the host and its herdr server.
    static func prefix(of connection: HostConnection) -> String {
        let key: String?
        if connection.config.kind == .local {
            if localHostKey == nil { localHostKey = PaneHandoff.hostKey(of: connection) }
            key = localHostKey
        } else {
            key = PaneHandoff.hostKey(of: connection)
        }
        let host = key ?? "local-\(connection.config.id.uuidString)"
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
        if keys.contains(key) {
            save(removing: [key])
        } else {
            save(adding: [key])
        }
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
        let gone = keys.filter { key in
            key.hasPrefix(prefix) && !panes.contains(String(key.dropFirst(prefix.count)))
        }
        if !gone.isEmpty { save(removing: gone) }
        #endif
    }

    #if !os(tvOS)
    /// Applies only this change to the store's local copy, so pins from
    /// other devices that already arrived stay. One array for all pins:
    /// iCloud keeps the last write, so two devices changing pins before
    /// either has the other's change lose one of them.
    private func save(adding added: Set<String> = [], removing removed: Set<String> = []) {
        guard let store else {
            keys = keys.subtracting(removed).union(added)
            return
        }
        let merged = Self.read(store).subtracting(removed).union(added)
        store.set(merged.sorted(), forKey: Self.storeKey)
        keys = merged
    }
    #endif
}
