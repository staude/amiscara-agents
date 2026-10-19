#if os(macOS)
import AppKit
import CloudKit
import Observation

/// Runs the answer keys and prompts the Watch leaves in iCloud when the
/// iPhone is out of reach (#160). Off by default: with it on, every device
/// of the same Apple ID can type into the agents of the hosts this Mac
/// pushes for. The host's "Eingaben erlauben" applies as well.
@MainActor
@Observable
final class CloudCommandReceiver {
    static let shared = CloudCommandReceiver()

    private static let enabledKey = "cloudCommands"

    /// Whether this Mac takes commands; saves or removes the subscription.
    var enabled: Bool {
        get { enabledSetting }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            enabledSetting = newValue
            Task { await installSubscription() }
        }
    }

    /// Mirrors the setting for observation.
    private var enabledSetting = UserDefaults.standard.bool(forKey: CloudCommandReceiver.enabledKey)
    private(set) var lastError: String?
    /// The last command run, for the settings.
    private(set) var lastCommand: (text: String, date: Date)?

    /// Whether this Mac runs commands for the host with this key
    /// fingerprint; another Mac may serve the others. Set by the store.
    @ObservationIgnored var serves: ((_ hostKey: String) -> Bool)?
    /// Runs a command; `nil` when it went out, else why not. Set by the
    /// store.
    @ObservationIgnored var run: ((CloudCommand) async -> String?)?
    /// Commands seen in this run of the app, so a repeated push does nothing.
    @ObservationIgnored private var seen: Set<String> = []

    private var database: CKDatabase { CloudPush.container.privateCloudDatabase }

    /// Saves the subscription when on, removes it when off. Called at launch
    /// and on every change; saving the same subscription again is harmless.
    func installSubscription() async {
        guard enabled else {
            _ = try? await database.modifySubscriptions(saving: [], deleting: [CloudCommand.subscriptionID])
            lastError = nil
            return
        }
        let subscription = CKQuerySubscription(
            recordType: CloudCommand.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: CloudCommand.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            lastError = nil
        } catch {
            // Until the Watch wrote its first command iCloud does not know
            // the record type and refuses the subscription; the next launch
            // tries again.
            lastError = String(localized: "iCloud: \(error.localizedDescription)")
        }
    }

    /// A push for a new command.
    func handle(_ userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == CloudCommand.subscriptionID,
              let id = notification.recordID
        else { return }
        await process(id)
    }

    private func process(_ id: CKRecord.ID) async {
        guard enabled, !seen.contains(id.recordName) else { return }
        seen.insert(id.recordName)
        guard let record = try? await database.record(for: id),
              let command = CloudCommand(record: record),
              serves?(command.hostKey) == true
        else { return }
        // Taken by deleting it: whoever deletes it first runs it, so it
        // runs once even with two Macs serving the same SSH host.
        guard (try? await database.deleteRecord(withID: id)) != nil else { return }
        let error: String?
        if Date.now.timeIntervalSince(record.creationDate ?? .distantPast) > CloudCommand.maxAge {
            error = String(localized: "Befehl abgelaufen.")
        } else if !command.isAllowed {
            error = String(localized: "Dieser Befehl ist nicht erlaubt.")
        } else if let run {
            error = await run(command)
        } else {
            error = String(localized: "Die App ist nicht bereit.")
        }
        if error == nil {
            lastCommand = (command.summary, .now)
        }
        _ = try? await database.save(CloudCommand.resultRecord(for: id, error: error))
    }
}

extension CloudCommand {
    /// "Taste 1" or the prompt, for the settings.
    var summary: String {
        switch action {
        case .key(let key): String(localized: "Taste \(key)")
        case .prompt(let text): String(localized: "Prompt „\(text.prefix(40))“")
        }
    }
}

extension HostStore {
    /// Wires the receiver to the hosts this Mac pushes for.
    func startCloudCommands() {
        let receiver = CloudCommandReceiver.shared
        receiver.serves = { [weak self] key in self?.commandConnection(key) != nil }
        receiver.run = { [weak self] command in
            await self?.run(command) ?? String(localized: "Die App ist nicht bereit.")
        }
        Task { await receiver.installSubscription() }
    }

    private func commandConnection(_ hostKey: String) -> HostConnection? {
        connections.first { cloudHost(of: $0)?.key == hostKey }
    }

    /// Answer keys only while the agent waits, prompts only while it does
    /// not: a command may arrive after the screen changed.
    private func run(_ command: CloudCommand) async -> String? {
        guard let connection = commandConnection(command.hostKey) else {
            return String(localized: "Diesen Host gibt es auf dem Mac nicht.")
        }
        let item = connection.update?.board.first { $0.paneId == command.paneID }
        do {
            switch command.action {
            case .key(let key):
                guard item?.agentState == .blocked else {
                    return String(localized: "Der Agent wartet nicht mehr.")
                }
                try await connection.send(keys: [key], to: command.paneID)
            case .prompt(let text):
                guard item != nil else { return String(localized: "Diesen Agent gibt es nicht mehr.") }
                try await connection.submit(text, to: command.paneID, isAgent: true)
            }
            return nil
        } catch {
            return inputErrorMessage(error)
        }
    }
}

/// Registers for remote notifications, which the command subscription
/// needs, and hands its pushes to the receiver.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        // Push payloads are property lists; they are not `Sendable`.
        nonisolated(unsafe) let userInfo = userInfo
        Task { @MainActor in await CloudCommandReceiver.shared.handle(userInfo) }
    }
}
#endif
