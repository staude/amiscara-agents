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
#if !os(tvOS)
@MainActor
@Observable
final class Notifier: NSObject {
    /// Set when a notification is tapped; the window opens it and clears it.
    var openRequest: SpaceRef?
    /// Start dictation in this pane's composer once it shows (#227).
    var dictateRequest: DictateRequest?

    /// Sends an answer key chosen on a notification (also on the Watch) to
    /// host and pane; true when it went out. Set by the store.
    @ObservationIgnored var answer: (@MainActor (_ hostID: UUID, _ paneID: String, _ key: String) async -> Bool)?
    /// The host a push from iCloud names by its host key fingerprint.
    @ObservationIgnored var hostForKey: (@MainActor (_ fingerprint: String) -> UUID?)?

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
    /// The fixed answers 1, 2, 3, Enter, Esc.
    @ObservationIgnored private let blockedCategory: UNNotificationCategory
    /// Categories with the options of a pane's question (#272), oldest
    /// first, one per pane.
    @ObservationIgnored private var questionCategories: [UNNotificationCategory] = []
    private static let maxQuestionCategories = 32
    /// More actions than these the system does not show; the rest is a tap
    /// away in the pane.
    private static let maxQuestionActions = 4

    override init() {
        // Answer buttons for "agent waits", local and pushed (#94). Not
        // `.foreground`: answering must not open the app, only send the key.
        // An answer can approve what an agent does, so a locked iPhone asks
        // for unlocking first; a worn, unlocked Watch counts as unlocked.
        let actions = AgentNotification.answers.map { answer in
            UNNotificationAction(identifier: "key.\(answer.key)", title: answer.title, options: [.authenticationRequired])
        }
        blockedCategory = UNNotificationCategory(identifier: AgentNotification.blockedCategory, actions: actions, intentIdentifiers: [])
        super.init()
        center.delegate = self
        center.setNotificationCategories([blockedCategory])
    }

    /// Posts one notification per agent that needs the user. `question`
    /// reads the choice question of a waiting agent's pane, whose options
    /// then become the answers (#272).
    func notify(
        _ items: [BoardItem],
        on host: HostConfig,
        question: (@MainActor (_ paneID: String) async -> ChoiceQuestion?)? = nil
    ) {
        guard host.notificationsOn, !items.isEmpty else { return }
        Task {
            guard await allowed() else { return }
            for item in items {
                if appActive, let visiblePane, visiblePane.hostID == host.id, visiblePane.paneID == item.paneId {
                    continue
                }
                var category: String?
                if item.agentState == .blocked {
                    let asked = await question?(item.paneId)
                    category = await self.category(for: asked, hostID: host.id, paneID: item.paneId)
                }
                try? await center.add(request(for: item, on: host, category: category))
            }
        }
    }

    /// The category for a waiting agent: the fixed answers, or a question's
    /// options as actions. Categories are registered all at once, so each
    /// pane keeps one, up to `maxQuestionCategories`.
    private func category(for question: ChoiceQuestion?, hostID: UUID, paneID: String) async -> String {
        guard let question, !question.options.isEmpty else { return AgentNotification.blockedCategory }
        let identifier = "\(AgentNotification.blockedCategory).\(hostID.uuidString).\(paneID)"
        let actions = question.options.prefix(Self.maxQuestionActions).map { option in
            UNNotificationAction(identifier: "key.\(option.key)", title: option.label, options: [.authenticationRequired])
        }
        questionCategories.removeAll { $0.identifier == identifier }
        questionCategories.append(UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: []))
        if questionCategories.count > Self.maxQuestionCategories {
            questionCategories.removeFirst(questionCategories.count - Self.maxQuestionCategories)
        }
        center.setNotificationCategories(Set([blockedCategory] + questionCategories))
        // Setting them returns at once; a notification posted before they
        // are in place would show no actions.
        _ = await center.notificationCategories()
        return identifier
    }

    /// App badge: agents waiting for an answer, over all hosts.
    func updateBadge(waiting: Int) {
        Task {
            guard await allowed() else { return }
            try? await center.setBadgeCount(waiting)
        }
    }

    private func request(for item: BoardItem, on host: HostConfig, category: String?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let text = AgentNotificationText(item: item, hostName: host.name)
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.sound = item.agentState == .blocked ? .default : nil
        if let category {
            content.categoryIdentifier = category
        }
        content.threadIdentifier = host.id.uuidString
        content.userInfo = [
            "host": host.id.uuidString,
            "workspace": item.workspaceId,
            "pane": item.paneId,
        ]
        // One notification per pane: a newer state replaces the older one.
        return UNNotificationRequest(identifier: AgentNotification.identifier(host.id, item.paneId), content: content, trigger: nil)
    }

    private func allowed() async -> Bool {
        // The screenshot demo (#199) neither asks nor notifies.
        if DemoMode.isOn { return false }
        if let authorized { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        return granted
    }

    private static func identifier(_ hostID: UUID, _ paneID: String) -> String {
        AgentNotification.identifier(hostID, paneID)
    }
}
#endif

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

#if !os(tvOS)
extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // While the app runs it posts its own notification for the pane;
        // the push through iCloud would only repeat it. A test push names
        // no pane and always shows.
        if notification.request.trigger is UNPushNotificationTrigger,
           CloudPush.target(of: notification.request.content.userInfo)?.paneID.isEmpty != true {
            return []
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let host: UUID, workspace: String, pane: String
        if let cloud = CloudPush.target(of: info) {
            // From iCloud: the Mac names its host by key fingerprint.
            guard let id = await hostForKey?(cloud.hostKey), !cloud.paneID.isEmpty else { return }
            (host, workspace, pane) = (id, cloud.workspaceID, cloud.paneID)
        } else if let id = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
                  let space = info["workspace"] as? String,
                  let paneID = info["pane"] as? String {
            (host, workspace, pane) = (id, space, paneID)
        } else {
            return
        }
        if let key = AgentNotification.key(forAction: response.actionIdentifier) {
            // An answer button, e.g. on the Watch: send the key, stay closed.
            _ = await answer?(host, pane, key)
            return
        }
        await MainActor.run {
            openRequest = SpaceRef(hostID: host, workspaceID: workspace, paneID: pane)
            // A shared prompt's pane may be on screen already (#225).
            NotificationCenter.default.post(name: PendingShare.arrived, object: nil)
        }
    }
}
#endif

#if os(tvOS)
/// tvOS shows no notification banners: the TV shows the agents' state on
/// screen. Same interface as on the other platforms, so the store needs no
/// branches.
@MainActor
@Observable
final class Notifier {
    var openRequest: SpaceRef?
    var dictateRequest: DictateRequest?
    @ObservationIgnored var answer: (@MainActor (_ hostID: UUID, _ paneID: String, _ key: String) async -> Bool)?
    @ObservationIgnored var hostForKey: (@MainActor (_ fingerprint: String) -> UUID?)?
    @ObservationIgnored var visiblePane: (hostID: UUID, paneID: String)?
    @ObservationIgnored var appActive = true

    func notify(
        _ items: [BoardItem],
        on host: HostConfig,
        question: (@MainActor (_ paneID: String) async -> ChoiceQuestion?)? = nil
    ) {}
    func updateBadge(waiting: Int) {}
}
#endif
