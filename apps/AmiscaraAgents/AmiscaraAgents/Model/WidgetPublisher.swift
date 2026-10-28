import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
#if os(tvOS)
import TVServices
#endif

/// Writes the board of all hosts for the widgets (`WidgetSnapshot`) and
/// reloads them: when the agents change, and every few minutes while the
/// app runs, so the widgets can say how fresh their data is. Outside the
/// Mac, hosts this device cannot reach take their agents from the boards
/// the Mac app leaves in iCloud (#156). The overview (#274) reads those
/// boards on every device, also on a Mac; its widgets show only what it
/// sees itself.
@MainActor
final class WidgetPublisher {
    private var written: WidgetSnapshot?
    private var timer: Timer?
    /// Longest gap between two writes while the app runs.
    private static let refresh: TimeInterval = 5 * 60

    #if os(iOS)
    /// Set by the store: fetches the Mac's boards after a silent push, for
    /// the Live Activity (#224); the widgets fetch them themselves.
    static var backgroundRefresh: (@MainActor () async -> Void)?
    #endif

    func start(_ store: HostStore) {
        timer = Timer.scheduledTimer(withTimeInterval: Self.refresh, repeats: true) { [weak self, weak store] _ in
            Task { @MainActor in
                guard let self, let store else { return }
                #if os(macOS)
                self.publish(store, force: true)
                #endif
                await self.refreshFromCloud(store)
            }
        }
        Task { await refreshFromCloud(store) }
    }

    /// Fetches the Mac's boards of this device's hosts into the store and,
    /// outside the Mac, publishes with them, e.g. at launch, in the
    /// foreground and every few minutes. A failed fetch keeps the boards
    /// fetched before.
    func refreshFromCloud(_ store: HostStore) async {
        let keys = store.connections.compactMap { CloudPush.hostKey(forPublicKey: $0.config.pinnedHostKey) }
        guard let boards = try? await CloudBoard.fetch(hostKeys: keys) else { return }
        store.cloudBoards = boards
        #if !os(macOS)
        publish(store, force: true)
        #endif
    }

    func publish(_ store: HostStore, force: Bool = false) {
        let hosts = store.connections.map { connection in
            WidgetSnapshot.Host(
                id: connection.id,
                name: connection.config.name,
                live: connection.isLive,
                agents: (connection.update?.board ?? []).map(WidgetSnapshot.Agent.init),
                hostKey: CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
            )
        }
        #if os(macOS)
        let snapshot = WidgetSnapshot(updated: .now, hosts: hosts)
        #else
        let snapshot = WidgetSnapshot(updated: .now, hosts: hosts).merging(store.cloudBoards)
        #endif
        #if !os(tvOS)
        store.updateShortcutAgents(snapshot)
        #endif
        #if os(iOS)
        AgentLiveActivity.shared.update(snapshot, store: store)
        #endif
        guard force || snapshot.hosts != written?.hosts else { return }
        #if os(iOS)
        // The Watch shows the same (#157).
        WatchBridge.shared.publish(snapshot)
        #endif
        do {
            try snapshot.save()
            written = snapshot
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
            #if os(iOS)
            // The waiting count of the Control Center control (#227).
            ControlCenter.shared.reloadControls(ofKind: WaitingControlKind.waiting)
            #endif
            #endif
            #if os(tvOS)
            // The Top Shelf reads the same snapshot (#130).
            TVTopShelfContentProvider.topShelfContentDidChange()
            #endif
        } catch {
            // Without the App Group (e.g. an unsigned build) there are no widgets.
        }
    }
}

extension WidgetSnapshot.Agent {
    init(_ item: BoardItem) {
        self.init(
            paneID: item.paneId,
            workspaceID: item.workspaceId,
            place: [item.workspaceName, item.tabLabel].filter { !$0.isEmpty }.joined(separator: " · "),
            name: item.name ?? item.agent,
            state: WidgetSnapshot.State(item.agentState),
            since: item.stateSinceMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        )
    }
}

extension WidgetSnapshot.State {
    init(_ state: AgentState) {
        switch state {
        case .blocked: self = .blocked
        case .working: self = .working
        case .done: self = .done
        case .idle: self = .idle
        case .unknown: self = .unknown
        }
    }
}
