import CloudKit
import Foundation
import Observation
import UserNotifications
import WatchConnectivity
import WatchKit

/// An agent the Watch can open: host and pane.
struct AgentRef: Hashable {
    let hostID: UUID
    let paneID: String
}

extension WidgetSnapshot {
    /// All agents, waiting first, with the reference to open them.
    var refs: [(ref: AgentRef, host: Host, agent: Agent)] {
        agents.map { (AgentRef(hostID: $0.host.id, paneID: $0.agent.paneID), $0.host, $0.agent) }
    }
}

/// What a waiting agent asks, as the Mac left it in iCloud (#156).
struct Excerpt: Equatable {
    let text: String
    let since: Date?
}

/// The Watch app's state (#157). The Watch cannot reach a host itself
/// (watchOS gives normal apps no sockets, and there is no NetBird), so the
/// agents come from the iPhone (application context) and from the boards
/// the Mac app writes into iCloud, and answers go to the iPhone, which sends
/// them over its SSH session.
@MainActor
@Observable
final class WatchStore: NSObject {
    /// The iPhone's snapshot merged with the Mac's boards.
    private(set) var snapshot: WidgetSnapshot
    private(set) var refreshing = false
    /// Set when a notification is tapped; the list opens it.
    var openRequest: AgentRef?

    /// The last snapshot from the iPhone, also across launches.
    @ObservationIgnored private var phoneSnapshot: WidgetSnapshot
    @ObservationIgnored private var boards: [CloudBoard] = []
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    private static let snapshotDefaultsKey = "phoneSnapshot"

    override init() {
        let stored = UserDefaults.standard.data(forKey: Self.snapshotDefaultsKey)
            .flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
        phoneSnapshot = stored ?? .empty
        snapshot = stored ?? .empty
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        center.delegate = self
        // With a Watch app installed, the Watch handles the answer buttons of
        // the iPhone's notifications itself, so it needs the same category.
        let actions = AgentNotification.answers.map { answer in
            UNNotificationAction(identifier: "key.\(answer.key)", title: answer.title, options: [.authenticationRequired])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AgentNotification.blockedCategory, actions: actions, intentIdentifiers: []),
        ])
    }

    func host(_ id: UUID) -> WidgetSnapshot.Host? {
        snapshot.hosts.first { $0.id == id }
    }

    func agent(_ ref: AgentRef) -> (host: WidgetSnapshot.Host, agent: WidgetSnapshot.Agent)? {
        guard let host = host(ref.hostID), let agent = host.agents.first(where: { $0.paneID == ref.paneID }) else { return nil }
        return (host, agent)
    }

    /// Fetches the Mac's boards of the iPhone's hosts.
    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let keys = phoneSnapshot.hosts.compactMap(\.hostKey)
        if let fetched = try? await CloudBoard.fetch(hostKeys: keys) {
            boards = fetched
        }
        snapshot = phoneSnapshot.merging(boards)
    }

    /// What a waiting agent asks, from its "wartet" record in iCloud.
    func excerpt(for ref: AgentRef) async -> Excerpt? {
        guard let hostKey = host(ref.hostID)?.hostKey else { return nil }
        let id = CKRecord.ID(recordName: CloudPush.recordName(CloudPush.waitingType, hostKey, ref.paneID))
        guard let record = try? await CloudPush.container.privateCloudDatabase.record(for: id),
              let text = record[CloudPush.Field.excerpt] as? String, !text.isEmpty
        else { return nil }
        return Excerpt(text: text, since: record.modificationDate)
    }

    /// Asks the iPhone to send `key`, or the Mac through iCloud when the
    /// iPhone is out of reach (#160); `nil` when it went out, else why not.
    func answer(_ key: String, to ref: AgentRef) async -> String? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            let error = await sendThroughCloud(.key(key), to: ref)
            WKInterfaceDevice.current().play(error == nil ? .success : .failure)
            return error
        }
        let message = WatchMessage.answer(host: ref.hostID, pane: ref.paneID, key: key)
        let error: String? = await withCheckedContinuation { continuation in
            session.sendMessage(message) { reply in
                continuation.resume(returning: WatchMessage.parseReply(reply))
            } errorHandler: { error in
                continuation.resume(returning: error.localizedDescription)
            }
        }
        WKInterfaceDevice.current().play(error == nil ? .success : .failure)
        return error
    }

    /// Leaves the command in iCloud for the Mac app on the host and waits
    /// for its result (#160). Without an answer in time the command is
    /// taken back, so it does not run late.
    private func sendThroughCloud(_ action: CloudCommand.Action, to ref: AgentRef) async -> String? {
        guard let hostKey = host(ref.hostID)?.hostKey else {
            return String(localized: "iPhone nicht erreichbar.")
        }
        let record = CloudCommand(hostKey: hostKey, paneID: ref.paneID, action: action).record()
        let database = CloudPush.container.privateCloudDatabase
        do {
            _ = try await database.save(record)
        } catch {
            return String(localized: "iPhone nicht erreichbar, iCloud: \(error.localizedDescription)")
        }
        let resultID = CloudCommand.resultID(for: record.recordID)
        for _ in 0..<Self.cloudWaitSeconds {
            try? await Task.sleep(for: .seconds(1))
            if let result = try? await database.record(for: resultID) {
                _ = try? await database.deleteRecord(withID: resultID)
                return CloudCommand.error(fromResult: result)
            }
        }
        _ = try? await database.deleteRecord(withID: record.recordID)
        return String(localized: "iPhone nicht erreichbar, und kein Mac hat den Befehl angenommen. Auf dem Mac „Befehle von der Apple Watch annehmen“ einschalten.")
    }

    /// How long the Watch waits for the Mac's result.
    private static let cloudWaitSeconds = 30

    /// The agent of a notification: pushes from iCloud name the host by its
    /// key fingerprint, the iPhone's own ones by its id.
    fileprivate func target(_ target: NotificationTarget) -> AgentRef? {
        switch target {
        case .hostKey(let key, let pane):
            snapshot.hosts.first { $0.hostKey == key }.map { AgentRef(hostID: $0.id, paneID: pane) }
        case .host(let id, let pane):
            AgentRef(hostID: id, paneID: pane)
        }
    }

    fileprivate func apply(phone data: Data) {
        guard let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        phoneSnapshot = decoded
        UserDefaults.standard.set(data, forKey: Self.snapshotDefaultsKey)
        snapshot = decoded.merging(boards)
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        guard let data = context[WatchMessage.snapshotKey] as? Data else { return }
        Task { @MainActor in apply(phone: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchMessage.snapshotKey] as? Data else { return }
        Task { @MainActor in apply(phone: data) }
    }
}

/// Host and pane as a notification names them.
private enum NotificationTarget: Sendable {
    case hostKey(String, pane: String)
    case host(UUID, pane: String)

    init?(_ info: [AnyHashable: Any]) {
        if let cloud = CloudPush.target(of: info) {
            guard !cloud.paneID.isEmpty else { return nil }
            self = .hostKey(cloud.hostKey, pane: cloud.paneID)
        } else if let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
                  let pane = info["pane"] as? String {
            self = .host(host, pane: pane)
        } else {
            return nil
        }
    }
}

extension WatchStore: UNUserNotificationCenterDelegate {
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
        guard let named = NotificationTarget(response.notification.request.content.userInfo) else { return }
        let key = AgentNotification.key(forAction: response.actionIdentifier)
        // Answered before returning, so watchOS keeps the app until the
        // iPhone replied.
        guard let ref = await target(named) else { return }
        if let key {
            _ = await answer(key, to: ref)
        } else {
            await MainActor.run { openRequest = ref }
        }
    }
}
