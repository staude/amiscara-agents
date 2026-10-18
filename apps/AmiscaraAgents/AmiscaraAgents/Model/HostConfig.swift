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

    var uploadAllowed: Bool {
        get { kind == .local || (allowUpload ?? false) }
        set { allowUpload = newValue }
    }

    static func local() -> HostConfig {
        HostConfig(name: String(localized: "Dieser Mac"), kind: .local)
    }
}
