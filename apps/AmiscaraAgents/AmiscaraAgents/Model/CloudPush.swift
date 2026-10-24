import CloudKit
import Foundation
import Observation
#if os(iOS)
import UIKit
import WidgetKit
#endif

extension CloudPush {
    /// The fingerprint both sides know a host by.
    static func hostKey(forPublicKey line: String?) -> String? {
        line.flatMap { try? publicKeyFingerprint(publicOpenssh: $0) }
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

    /// Whether events of the SSH hosts go out too (#125), not only those of
    /// this Mac; then one running Mac covers hosts without a Mac app.
    var includeSSHHosts: Bool {
        get { UserDefaults.standard.object(forKey: "cloudPushSSHHosts") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "cloudPushSSHHosts")
            sshHostsSetting = newValue
        }
    }

    /// Mirrors the setting for observation.
    private var sshHostsSetting = true

    /// A record written within this time with the same title and text counts
    /// as the same event, e.g. from another Mac or the host's own Mac app.
    private static let duplicateWindow: TimeInterval = 60

    /// Fetches the screen excerpt of a waiting agent's pane; `nil` when the
    /// pane cannot be read.
    typealias ExcerptReader = @MainActor (_ paneID: String) async -> String?

    /// Events of the host with key fingerprint `hostKey`; skipped when
    /// another Mac wrote the same event a moment ago, so no push comes twice.
    func send(_ items: [BoardItem], hostKey: String, hostName: String, excerpt: @escaping ExcerptReader) {
        guard !items.isEmpty else { return }
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
        Task {
            let existing = (try? await CloudPush.container.privateCloudDatabase.records(for: records.map(\.recordID))) ?? [:]
            let fresh = records.filter { record in
                guard case .success(let stored)? = existing[record.recordID],
                      let changed = stored.modificationDate,
                      Date.now.timeIntervalSince(changed) < Self.duplicateWindow
                else { return true }
                return stored[CloudPush.Field.title] as? String != record[CloudPush.Field.title] as? String
                    || stored[CloudPush.Field.body] as? String != record[CloudPush.Field.body] as? String
            }
            guard !fresh.isEmpty else { return }
            for record in fresh where record.recordType == CloudPush.waitingType {
                if let paneID = record[CloudPush.Field.paneID] as? String,
                   let text = await excerpt(paneID), !text.isEmpty {
                    record[CloudPush.Field.excerpt] = text
                }
            }
            save(fresh)
        }
    }

    // MARK: Boards (#156)

    /// Shortest gap between two board writes of one host.
    private static let boardInterval: TimeInterval = 10
    /// Boards are rewritten this often even without a change, so devices
    /// can tell a quiet host from a Mac that stopped (`CloudBoard.maxAge`).
    private static let boardRefresh: TimeInterval = 5 * 60

    /// The latest board per host key, written or not.
    @ObservationIgnored private var boards: [String: CloudBoard] = [:]
    @ObservationIgnored private var writtenBoards: [String: CloudBoard] = [:]
    @ObservationIgnored private var boardWrites: [String: Date] = [:]
    @ObservationIgnored private var pendingBoards: Set<String> = []
    @ObservationIgnored private var boardTimer: Timer?

    /// The agents of the host with key fingerprint `hostKey`, for devices
    /// that cannot reach it. Written right away after a quiet time, else at
    /// most every `boardInterval`, with the newest state.
    func sendBoard(_ items: [BoardItem], live: Bool, hostKey: String, hostName: String) {
        let board = CloudBoard(
            hostKey: hostKey,
            hostName: hostName,
            live: live,
            updated: .now,
            agents: items.map(WidgetSnapshot.Agent.init)
        )
        boards[hostKey] = board
        startBoardTimer()
        if let written = writtenBoards[hostKey], written.sameContent(as: board) { return }
        scheduleBoard(hostKey)
    }

    /// Deletes the board of a host removed from this Mac, so devices stop
    /// showing its agents.
    func removeBoard(hostKey: String) {
        boards[hostKey] = nil
        writtenBoards[hostKey] = nil
        boardWrites[hostKey] = nil
        let operation = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: [CloudBoard.recordID(hostKey: hostKey)]
        )
        operation.qualityOfService = .utility
        CloudPush.container.privateCloudDatabase.add(operation)
    }

    private func scheduleBoard(_ hostKey: String) {
        guard !pendingBoards.contains(hostKey) else { return }
        pendingBoards.insert(hostKey)
        let since = Date.now.timeIntervalSince(boardWrites[hostKey] ?? .distantPast)
        let wait = max(0, Self.boardInterval - since)
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.writeBoard(hostKey)
        }
    }

    private func writeBoard(_ hostKey: String) {
        pendingBoards.remove(hostKey)
        guard let latest = boards[hostKey] else { return }
        let board = CloudBoard(
            hostKey: latest.hostKey,
            hostName: latest.hostName,
            live: latest.live,
            updated: .now,
            agents: latest.agents
        )
        boardWrites[hostKey] = board.updated
        writtenBoards[hostKey] = board
        save([board.record])
    }

    private func startBoardTimer() {
        guard boardTimer == nil else { return }
        boardTimer = Timer.scheduledTimer(withTimeInterval: Self.boardRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for hostKey in self.boards.keys where !self.pendingBoards.contains(hostKey) {
                    self.writeBoard(hostKey)
                }
            }
        }
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
/// Subscribes this device to the events the Mac writes. Installed at every
/// launch and return to the foreground: saving the same subscriptions again
/// is harmless, and a first attempt can fail while a new container is not
/// ready yet or iCloud is signed out.
@MainActor
@Observable
final class CloudPushSubscriptions {
    static let shared = CloudPushSubscriptions()

    /// For the host settings: whether pushes can arrive, or why not.
    private(set) var status: String?
    private(set) var active = false

    func install() async {
        let account = try? await CloudPush.container.accountStatus()
        guard account == .available else {
            active = false
            status = String(localized: "Nicht bei iCloud angemeldet. Mac und iPhone brauchen dieselbe Apple-ID.")
            return
        }
        let subscriptions = [
            Self.subscription(CloudPush.waitingType, waiting: true),
            Self.subscription(CloudPush.doneType, waiting: false),
        ]
        do {
            _ = try await CloudPush.container.privateCloudDatabase.modifySubscriptions(saving: subscriptions, deleting: [])
            active = true
            status = String(localized: "Aktiv: „wartet“ und „fertig“ kommen über iCloud, wenn die Mac-App auf dem Host läuft.")
            // On its own: until a Mac wrote the first board, iCloud does not
            // know the record type and refuses the subscription.
            _ = try? await CloudPush.container.privateCloudDatabase.modifySubscriptions(saving: [Self.boardSubscription], deleting: [])
        } catch {
            active = false
            status = String(localized: "iCloud-Abo fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    static let boardSubscriptionID = "\(CloudBoard.recordType)-v1"

    /// A silent push per new board (#156), so the widgets fetch it. iOS
    /// rations silent pushes; the widgets also fetch every few minutes.
    private static var boardSubscription: CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: CloudBoard.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: boardSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
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
        // Before anything else: a Watch answer may have launched the app.
        WatchBridge.shared.activate()
        Task { await CloudPushSubscriptions.shared.install() }
        return true
    }

    /// A new board from the Mac: the widgets fetch it themselves.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
            == CloudPushSubscriptions.boardSubscriptionID
        else { return .noData }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        await WidgetPublisher.backgroundRefresh?()
        return .newData
    }
}
#endif
