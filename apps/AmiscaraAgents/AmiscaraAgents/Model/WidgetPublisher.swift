import Foundation
import WidgetKit

/// Writes the board of all hosts for the widgets (`WidgetSnapshot`) and
/// reloads them: when the agents change, and every few minutes while the
/// app runs, so the widgets can say how fresh their data is.
@MainActor
final class WidgetPublisher {
    private var written: WidgetSnapshot?
    private var timer: Timer?
    /// Longest gap between two writes while the app runs.
    private static let refresh: TimeInterval = 5 * 60

    func start(_ store: HostStore) {
        timer = Timer.scheduledTimer(withTimeInterval: Self.refresh, repeats: true) { [weak self, weak store] _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.publish(store, force: true)
            }
        }
    }

    func publish(_ store: HostStore, force: Bool = false) {
        let hosts = store.connections.map { connection in
            WidgetSnapshot.Host(
                id: connection.id,
                name: connection.config.name,
                live: connection.isLive,
                agents: (connection.update?.board ?? []).map { item in
                    WidgetSnapshot.Agent(
                        paneID: item.paneId,
                        workspaceID: item.workspaceId,
                        place: [item.workspaceName, item.tabLabel].filter { !$0.isEmpty }.joined(separator: " · "),
                        name: item.name ?? item.agent,
                        state: WidgetSnapshot.State(item.agentState)
                    )
                }
            )
        }
        guard force || hosts != written?.hosts else { return }
        let snapshot = WidgetSnapshot(updated: .now, hosts: hosts)
        do {
            try snapshot.save()
            written = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        } catch {
            // Without the App Group (e.g. an unsigned build) there are no widgets.
        }
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
