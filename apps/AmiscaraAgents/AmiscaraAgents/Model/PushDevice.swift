import Foundation

/// An iPhone or iPad that wants pushes for one host (#94). The device writes
/// it to `~/.amiscara-agents/push/<id>.json` on that host over SFTP; the Mac
/// app on the host reads these files and sends through APNs.
struct PushDevice: Codable, Equatable {
    /// APNs device token, hex.
    let token: String
    /// `development` for debug builds (APNs sandbox), else `production`.
    let environment: String
    /// The device's own id and name for this host, so a push opens the
    /// right pane and says the name the device uses.
    let hostID: UUID
    let hostName: String
    let deviceName: String
    let updated: Date

    var sandbox: Bool { environment == "development" }
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

    /// The same id for a pane's local notification and its push, so one
    /// replaces the other instead of showing twice.
    static func identifier(_ hostID: UUID, _ paneID: String) -> String {
        "\(hostID.uuidString)/\(paneID)"
    }
}
