import CloudKit
import Foundation

/// Pushes through CloudKit (#119): the Mac app on the host writes "agent
/// waits / is done" into the user's private iCloud database, iPhones and
/// iPads of the same Apple ID subscribe, and Apple sends the push. No key,
/// no server; the data stays in the user's iCloud.
///
/// One record per pane and state, overwritten on every change, so the
/// database does not grow. Devices find the host by the fingerprint of its
/// SSH host key, which they pinned when they added it.
///
/// Shared with the widgets and the Watch, which have no FFI; the app adds
/// `hostKey(forPublicKey:)`.
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
        /// Waiting only: the last lines of the screen as plain text, so a
        /// small screen such as the Watch shows what is asked (#156).
        static let excerpt = "excerpt"
    }

    /// Lines of the screen in `Field.excerpt`.
    static let excerptLines: UInt32 = 12

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
    static func recordName(_ parts: String...) -> String {
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
