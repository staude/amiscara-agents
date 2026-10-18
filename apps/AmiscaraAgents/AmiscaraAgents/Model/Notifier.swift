import Foundation
import Observation
import UserNotifications

/// Local notifications when an agent starts waiting or finishes. The core
/// reports those changes (`SessionUpdate.attention`); this posts them, keeps
/// the app badge at the number of waiting agents and opens the pane when a
/// notification is tapped.
///
/// On iOS this only works while the app runs: in the background the system
/// suspends it and the SSH session with it.
@MainActor
@Observable
final class Notifier: NSObject {
    /// Set when a notification is tapped; the window opens it and clears it.
    var openRequest: SpaceRef?

    /// The pane on screen, which gets no banner for its own changes.
    @ObservationIgnored var visiblePane: (hostID: UUID, paneID: String)? {
        didSet {
            guard let visiblePane else { return }
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(visiblePane.hostID, visiblePane.paneID)])
        }
    }

    /// While the app is in front, the visible pane gets no banner.
    @ObservationIgnored var appActive = true

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var authorized: Bool?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Posts one notification per agent that needs the user.
    func notify(_ items: [BoardItem], on host: HostConfig) {
        guard host.notificationsOn, !items.isEmpty else { return }
        Task {
            guard await allowed() else { return }
            for item in items {
                if appActive, let visiblePane, visiblePane.hostID == host.id, visiblePane.paneID == item.paneId {
                    continue
                }
                try? await center.add(request(for: item, on: host))
            }
        }
    }

    /// App badge: agents waiting for an answer, over all hosts.
    func updateBadge(waiting: Int) {
        Task {
            guard await allowed() else { return }
            try? await center.setBadgeCount(waiting)
        }
    }

    private func request(for item: BoardItem, on host: HostConfig) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let agent = item.agent.isEmpty ? String(localized: "Agent") : item.agent
        content.title = item.agentState == .blocked
            ? String(localized: "\(agent) wartet")
            : String(localized: "\(agent) ist fertig")
        content.subtitle = "\(host.name) · \(item.spacePlace) · Tab \(item.tabLabel)"
        content.body = item.title
        content.sound = item.agentState == .blocked ? .default : nil
        content.threadIdentifier = host.id.uuidString
        content.userInfo = [
            "host": host.id.uuidString,
            "workspace": item.workspaceId,
            "pane": item.paneId,
        ]
        // One notification per pane: a newer state replaces the older one.
        return UNNotificationRequest(identifier: Self.identifier(host.id, item.paneId), content: content, trigger: nil)
    }

    private func allowed() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        return granted
    }

    private static func identifier(_ hostID: UUID, _ paneID: String) -> String {
        "\(hostID.uuidString)/\(paneID)"
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
              let workspace = info["workspace"] as? String,
              let pane = info["pane"] as? String
        else { return }
        await MainActor.run {
            openRequest = SpaceRef(hostID: host, workspaceID: workspace, paneID: pane)
        }
    }
}
