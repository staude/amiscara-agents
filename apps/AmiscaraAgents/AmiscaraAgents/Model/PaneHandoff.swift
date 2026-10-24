import Foundation

/// Handoff of the open pane between Mac, iPhone and iPad (#231). Host
/// entries differ per device, so the host travels as its SSH host key
/// fingerprint, as for the iCloud pushes, plus the herdr session name.
enum PaneHandoff {
    static let activityType = "net.staude.amiscara.agents.pane"

    private enum Key {
        static let hostKey = "hostKey"
        static let session = "session"
        static let workspace = "workspace"
        static let pane = "pane"
    }

    struct Target: Equatable {
        let hostKey: String
        /// Empty for the default session.
        let session: String
        let workspaceID: String
        let paneID: String?
    }

    /// The fingerprint other devices know this host by: the Mac's own key
    /// for its local host, the pinned key for an SSH host.
    @MainActor
    static func hostKey(of connection: HostConnection) -> String? {
        switch connection.config.kind {
        case .local: CloudPush.hostKey(forPublicKey: Platform.localHostKey())
        case .ssh: CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
        }
    }

    @MainActor
    static func session(of connection: HostConnection) -> String {
        sessionNameOfSocket(socketPath: connection.config.socketPath) ?? ""
    }

    /// Fills the activity for the shown pane; `false` when the host cannot
    /// be named to another device (no host key known).
    @MainActor
    static func describe(
        _ activity: NSUserActivity,
        connection: HostConnection,
        workspaceID: String,
        paneID: String?,
        title: String
    ) -> Bool {
        guard let hostKey = hostKey(of: connection) else { return false }
        var info: [String: String] = [
            Key.hostKey: hostKey,
            Key.session: session(of: connection),
            Key.workspace: workspaceID,
        ]
        if let paneID { info[Key.pane] = paneID }
        activity.title = title
        activity.userInfo = info
        activity.requiredUserInfoKeys = [Key.hostKey, Key.session, Key.workspace]
        activity.isEligibleForHandoff = true
        // Pane ids and host keys are nothing for search or prediction.
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        return true
    }

    static func target(from activity: NSUserActivity) -> Target? {
        guard activity.activityType == activityType,
              let info = activity.userInfo,
              let hostKey = info[Key.hostKey] as? String,
              let workspaceID = info[Key.workspace] as? String
        else { return nil }
        return Target(
            hostKey: hostKey,
            session: info[Key.session] as? String ?? "",
            workspaceID: workspaceID,
            paneID: info[Key.pane] as? String
        )
    }

    /// This device's host entry for the target, if it has one.
    @MainActor
    static func resolve(_ target: Target, in store: HostStore) -> SpaceRef? {
        guard let connection = store.connections.first(where: {
            hostKey(of: $0) == target.hostKey && session(of: $0) == target.session
        }) else { return nil }
        return SpaceRef(hostID: connection.id, workspaceID: target.workspaceID, paneID: target.paneID)
    }
}
