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

    /// Sends an answer key chosen on a notification (also on the Watch) to
    /// host and pane; true when it went out. Set by the store.
    @ObservationIgnored var answer: (@MainActor (_ hostID: UUID, _ paneID: String, _ key: String) async -> Bool)?

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
        // Answer buttons for "agent waits", local and pushed (#94). Not
        // `.foreground`: answering must not open the app, only send the key.
        let actions = AgentNotification.answers.map { answer in
            UNNotificationAction(identifier: "key.\(answer.key)", title: answer.title, options: [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AgentNotification.blockedCategory, actions: actions, intentIdentifiers: []),
        ])
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
        let text = AgentNotificationText(item: item, hostName: host.name)
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.sound = item.agentState == .blocked ? .default : nil
        if item.agentState == .blocked {
            content.categoryIdentifier = AgentNotification.blockedCategory
        }
        content.threadIdentifier = host.id.uuidString
        content.userInfo = [
            "host": host.id.uuidString,
            "workspace": item.workspaceId,
            "pane": item.paneId,
        ]
        // One notification per pane: a newer state replaces the older one.
        // The push for the same pane uses this id as collapse id.
        return UNNotificationRequest(identifier: AgentNotification.identifier(host.id, item.paneId), content: content, trigger: nil)
    }

    private func allowed() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        return granted
    }

    private static func identifier(_ hostID: UUID, _ paneID: String) -> String {
        AgentNotification.identifier(hostID, paneID)
    }
}

/// Title, subtitle and body of an agent notification, shared by the local
/// notifications and the pushes the Mac sends.
struct AgentNotificationText {
    let title: String
    let subtitle: String
    let body: String

    init(item: BoardItem, hostName: String) {
        let agent = item.agent.isEmpty ? String(localized: "Agent") : item.agent
        title = item.agentState == .blocked
            ? String(localized: "\(agent) wartet")
            : String(localized: "\(agent) ist fertig")
        subtitle = "\(hostName) · \(item.spacePlace) · Tab \(item.tabLabel)"
        body = item.title
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // While the app runs it posts its own notification for the pane;
        // the push from the Mac would only repeat it.
        if notification.request.trigger is UNPushNotificationTrigger {
            return []
        }
        return [.banner, .list, .sound]
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
        if let key = AgentNotification.key(forAction: response.actionIdentifier) {
            // An answer button, e.g. on the Watch: send the key, stay closed.
            _ = await answer?(host, pane, key)
            return
        }
        await MainActor.run {
            openRequest = SpaceRef(hostID: host, workspaceID: workspace, paneID: pane)
        }
    }
}
