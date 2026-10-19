import CloudKit
import Foundation

/// An answer key or prompt the Watch leaves in the user's private iCloud
/// database when the iPhone is out of reach (#160). The Mac app on the
/// host runs it over its own connection, if "Befehle über iCloud" is on
/// there, and writes a `Result` back. Shared by the Mac app and the Watch;
/// no FFI types in here.
struct CloudCommand: Equatable {
    /// Fingerprint of the host's SSH host key, as in `CloudPush`.
    let hostKey: String
    let paneID: String
    let action: Action

    enum Action: Equatable {
        /// One of `AgentNotification.answers`.
        case key(String)
        case prompt(String)
    }

    static let recordType = "AgentCommand"
    static let resultType = "AgentCommandResult"
    static let subscriptionID = "\(recordType)-v1"

    /// Older commands are not run: the answer may no longer fit the screen.
    static let maxAge: TimeInterval = 60
    /// Longer prompts are refused; the Watch has no use for them.
    static let maxPromptLength = 4000

    enum Field {
        static let hostKey = "hostKey"
        static let paneID = "paneID"
        static let key = "key"
        static let text = "text"
        static let ok = "ok"
        static let error = "error"
    }

    /// Whether the Mac may run it: only the fixed answer keys and prompts
    /// of a sane length, nothing else herdr offers.
    var isAllowed: Bool {
        switch action {
        case .key(let key):
            AgentNotification.answers.contains { $0.key == key }
        case .prompt(let text):
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maxPromptLength
        }
    }

    /// A new record with a name of its own, so each command runs once.
    func record() -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: "\(Self.recordType)-\(UUID().uuidString)")
        )
        record[Field.hostKey] = hostKey
        record[Field.paneID] = paneID
        switch action {
        case .key(let key): record[Field.key] = key
        case .prompt(let text): record[Field.text] = text
        }
        return record
    }

    init(hostKey: String, paneID: String, action: Action) {
        self.hostKey = hostKey
        self.paneID = paneID
        self.action = action
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let hostKey = record[Field.hostKey] as? String,
              let paneID = record[Field.paneID] as? String
        else { return nil }
        if let key = record[Field.key] as? String {
            action = .key(key)
        } else if let text = record[Field.text] as? String {
            action = .prompt(text)
        } else {
            return nil
        }
        self.hostKey = hostKey
        self.paneID = paneID
    }

    /// Where the Mac answers the command `id`.
    static func resultID(for id: CKRecord.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(resultType)-\(id.recordName)")
    }

    /// The Mac's answer: `nil` when the command ran, else why not.
    static func resultRecord(for id: CKRecord.ID, error: String?) -> CKRecord {
        let record = CKRecord(recordType: resultType, recordID: resultID(for: id))
        record[Field.ok] = error == nil
        if let error { record[Field.error] = error }
        return record
    }

    /// `nil` when the command ran, else the reason from the Mac.
    static func error(fromResult record: CKRecord) -> String? {
        record[Field.ok] as? Bool == true
            ? nil
            : record[Field.error] as? String ?? String(localized: "Der Mac hat den Befehl nicht ausgeführt.")
    }
}
