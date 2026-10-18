import CloudKit
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Pushes through CloudKit (#119): the Mac app on the host writes "agent
/// waits / is done" into the user's private iCloud database, iPhones and
/// iPads of the same Apple ID subscribe, and Apple sends the push. No key,
/// no server; the data stays in the user's iCloud.
///
/// One record per pane and state, overwritten on every change, so the
/// database does not grow. Devices find the host by the fingerprint of its
/// SSH host key, which they pinned when they added it.
enum CloudPush {
    static let container = CKContainer(identifier: "iCloud.net.staude.amiscara.agents")
    static let waitingType = "AgentWaiting"
    static let doneType = "AgentDone"

    enum Field {
        static let hostKey = "hostKey"
        static let paneID = "paneID"
        static let workspaceID = "workspaceID"
        static let title = "title"
        static let subtitle = "subtitle"
        static let body = "body"
        static let collapseID = "collapseID"
    }

    /// The fingerprint both sides know a host by.
    static func hostKey(forPublicKey line: String?) -> String? {
        line.flatMap { try? publicKeyFingerprint(publicOpenssh: $0) }
    }

    /// The host and pane a tapped or answered push is about.
    static func target(of userInfo: [AnyHashable: Any]) -> (hostKey: String, workspaceID: String, paneID: String)? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields,
              let hostKey = fields[Field.hostKey] as? String,
              let workspace = fields[Field.workspaceID] as? String,
              let pane = fields[Field.paneID] as? String
        else { return nil }
        return (hostKey, workspace, pane)
    }

    /// Record names allow letters, digits, `-` and `_`.
    fileprivate static func recordName(_ parts: String...) -> String {
        String(parts.joined(separator: "-").map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

/// Category of "agent waits" notifications, local and pushed: one action
/// per answer key, so the Watch can answer without opening the app.
enum AgentNotification {
    static let blockedCategory = "agent-blocked"

    /// Action identifier `key.<herdr key>` and its title.
    static let answers: [(key: String, title: String)] = [
        ("1", "1"), ("2", "2"), ("3", "3"), ("enter", "Enter"), ("esc", "Esc"),
    ]

    static func key(forAction identifier: String) -> String? {
        identifier.hasPrefix("key.") ? String(identifier.dropFirst(4)) : nil
    }

    static func identifier(_ hostID: UUID, _ paneID: String) -> String {
        "\(hostID.uuidString)/\(paneID)"
    }
}

#if os(macOS)
/// Writes the events of this Mac's own host for the subscribed devices.
@MainActor
@Observable
final class CloudPushSender {
    /// iCloud state for the settings, `nil` while unknown.
    private(set) var accountStatus: CKAccountStatus?
    private(set) var lastError: String?
    /// This Mac's SSH host key fingerprint; without it devices cannot tell
    /// which host an event is from.
    let hostKey = CloudPush.hostKey(forPublicKey: Platform.localHostKey())

    func refreshAccount() async {
        accountStatus = try? await CloudPush.container.accountStatus()
    }

    func send(_ items: [BoardItem], hostName: String) {
        guard let hostKey, !items.isEmpty else { return }
        let records = items.map { item in
            let waiting = item.agentState == .blocked
            let type = waiting ? CloudPush.waitingType : CloudPush.doneType
            let record = CKRecord(
                recordType: type,
                recordID: CKRecord.ID(recordName: CloudPush.recordName(type, hostKey, item.paneId))
            )
            let text = AgentNotificationText(item: item, hostName: hostName)
            record[CloudPush.Field.hostKey] = hostKey
            record[CloudPush.Field.paneID] = item.paneId
            record[CloudPush.Field.workspaceID] = item.workspaceId
            record[CloudPush.Field.title] = text.title
            record[CloudPush.Field.subtitle] = text.subtitle
            record[CloudPush.Field.body] = text.body.isEmpty ? " " : text.body
            record[CloudPush.Field.collapseID] = CloudPush.recordName(hostKey, item.paneId)
            return record
        }
        save(records)
    }

    /// A "done" event that says the path works.
    func sendTest() {
        guard let hostKey else {
            lastError = String(localized: "Ohne SSH-Host-Key dieses Macs (entfernte Anmeldung an) erkennen die Geräte den Host nicht.")
            return
        }
        let record = CKRecord(
            recordType: CloudPush.doneType,
            recordID: CKRecord.ID(recordName: CloudPush.recordName("test", hostKey))
        )
        record[CloudPush.Field.hostKey] = hostKey
        record[CloudPush.Field.paneID] = ""
        record[CloudPush.Field.workspaceID] = ""
        record[CloudPush.Field.title] = String(localized: "Amiscara Agents")
        record[CloudPush.Field.subtitle] = Host.current().localizedName ?? "Mac"
        record[CloudPush.Field.body] = String(localized: "Test vom Mac: Push über iCloud kommt an.")
        record[CloudPush.Field.collapseID] = "test"
        save([record])
    }

    /// Overwrites whole records: no change tags needed, and every save
    /// fires the devices' subscriptions.
    private func save(_ records: [CKRecord]) {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .allKeys
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsResultBlock = { [weak self] result in
            let message: String? = switch result {
            case .success: nil
            case .failure(let error): String(localized: "iCloud: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.lastError = message }
        }
        CloudPush.container.privateCloudDatabase.add(operation)
    }
}
#endif

#if os(iOS)
/// Subscribes this device to the events the Mac writes.
enum CloudPushSubscriptions {
    static func install() async {
        guard (try? await CloudPush.container.accountStatus()) == .available else { return }
        let subscriptions = [
            subscription(CloudPush.waitingType, waiting: true),
            subscription(CloudPush.doneType, waiting: false),
        ]
        _ = try? await CloudPush.container.privateCloudDatabase.modifySubscriptions(saving: subscriptions, deleting: [])
    }

    private static func subscription(_ type: String, waiting: Bool) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: type,
            predicate: NSPredicate(value: true),
            subscriptionID: "\(type)-v1",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        // The key is no translation, so it serves as the format.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = [CloudPush.Field.title]
        info.subtitleLocalizationKey = "%1$@"
        info.subtitleLocalizationArgs = [CloudPush.Field.subtitle]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = [CloudPush.Field.body]
        info.desiredKeys = [CloudPush.Field.hostKey, CloudPush.Field.paneID, CloudPush.Field.workspaceID]
        info.collapseIDKey = CloudPush.Field.collapseID
        if waiting {
            info.soundName = "default"
            info.category = AgentNotification.blockedCategory
        }
        subscription.notificationInfo = info
        return subscription
    }
}

/// Registers for remote notifications, which CloudKit subscriptions need.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        Task { await CloudPushSubscriptions.install() }
        return true
    }
}
#endif
