import Foundation

/// A herdr server the app knows. Private keys never live here, only in the
/// Keychain (see `KeyStore`).
struct HostConfig: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The Unix socket on this Mac.
        case local
        /// A remote server over SSH streamlocal.
        case ssh
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var host = ""
    var port = 22
    var user = ""
    /// Path of `herdr.sock` on the server. Empty means the default.
    var socketPath = ""
    /// Trusted host key as an OpenSSH public key line, set after the user
    /// confirmed the fingerprint on first contact.
    var pinnedHostKey: String?
    /// Public half of this device's key, shown for `authorized_keys`.
    var publicKey: String?
    /// Whether the app may send prompts and keys to this host. Optional so
    /// host files from before this switch still load; missing means on.
    var allowInput: Bool?

    var inputAllowed: Bool {
        get { allowInput ?? true }
        set { allowInput = newValue }
    }
    /// Whether images may be uploaded over SFTP. Off by default: the key
    /// line then runs `sftp-server`, which can read and write every file of
    /// the user on that host.
    var allowUpload: Bool?

    /// Notifications when an agent waits or finishes; missing means on.
    var notify: Bool?

    var notificationsOn: Bool {
        get { notify ?? true }
        set { notify = newValue }
    }

    /// Whether spaces named "Bereich/Name" are grouped in the sidebar
    /// (see `SpaceNames`). Missing means on: hosts saved before this switch
    /// already used the convention.
    var groupSpaces: Bool?

    var groupSpacesByName: Bool {
        get { groupSpaces ?? true }
        set { groupSpaces = newValue }
    }

    /// How the sidebar orders spaces; missing means herdr's order.
    var spaceSort: SpaceSortMode?
    /// Workspace IDs in the user's order, for `SpaceSortMode.manual`.
    var spaceOrder: [String]?

    /// What the session sorts by (see `herdr_core::spaces::SpaceSort`).
    var spaceSorting: SpaceSort {
        switch spaceSort ?? .herdr {
        case .herdr: .herdr
        case .nameAscending: .nameAscending
        case .nameDescending: .nameDescending
        case .manual: .manual(order: spaceOrder ?? [])
        }
    }

    var uploadAllowed: Bool {
        get { kind == .local || (allowUpload ?? false) }
        set { allowUpload = newValue }
    }

    /// Whether the key line lets pages on the host's `localhost` through,
    /// for pages agents open there (#247). Missing means off.
    var allowWebForward: Bool?

    var webForwardAllowed: Bool {
        get { allowWebForward ?? false }
        set { allowWebForward = newValue }
    }

    /// SSH target VS Code connects to for "In VS Code öffnen" (#288), e.g.
    /// an alias from the client's `~/.ssh/config`. Missing means
    /// `user@host` of this connection.
    var sshTarget: String?

    /// The Remote-SSH target for VS Code; nil for this Mac, whose folders
    /// open directly.
    var editorTarget: String? {
        guard kind == .ssh else { return nil }
        let target = (sshTarget ?? "").trimmingCharacters(in: .whitespaces)
        if !target.isEmpty { return target }
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// The user's choice whether this host is reached over NetBird (#305);
    /// missing means automatic.
    var viaNetBird: Bool?
    /// Learned while NetBird was up: the name resolved to a NetBird address.
    var netBirdLearned: Bool?

    /// Whether the app expects NetBird to be needed for this host.
    var behindNetBird: Bool {
        guard kind == .ssh else { return false }
        return NetBird.isBehind(switch: viaNetBird, host: host, learned: netBirdLearned)
    }

    static func local() -> HostConfig {
        HostConfig(name: String(localized: "Dieser Mac"), kind: .local)
    }
}

/// The order of spaces in the sidebar, per host and device.
enum SpaceSortMode: String, Codable, CaseIterable, Sendable {
    case herdr, nameAscending, nameDescending, manual

    var label: String {
        switch self {
        case .herdr: String(localized: "wie herdr")
        case .nameAscending: String(localized: "Name A–Z")
        case .nameDescending: String(localized: "Name Z–A")
        case .manual: String(localized: "Manuell")
        }
    }
}
