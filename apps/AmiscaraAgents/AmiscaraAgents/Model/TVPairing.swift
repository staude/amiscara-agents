import CloudKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Pairing an Apple TV with the iPhone (#127). The TV makes its own SSH key
/// and shows `amiscara-agents://pair-tv?...` as a QR code; the iPhone adds
/// the key, restricted to the herdr socket, to `authorized_keys` on the
/// chosen hosts and leaves the host data for the TV in the private iCloud
/// database. The TV's private key never leaves it.
enum TVPairing {
    /// One record per TV, read by id: no query, no index.
    static let recordType = "TVPairing"
    static let hostsField = "hosts"

    struct Link: Equatable, Identifiable {
        let tvID: String
        let name: String
        /// The TV's public key as one OpenSSH line.
        let publicKey: String

        var id: String { tvID }

        var url: URL {
            var components = URLComponents()
            components.scheme = "amiscara-agents"
            components.host = "pair-tv"
            components.queryItems = [
                URLQueryItem(name: "v", value: "1"),
                URLQueryItem(name: "id", value: tvID),
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "key", value: publicKey),
            ]
            return components.url!
        }

        init(tvID: String, name: String, publicKey: String) {
            self.tvID = tvID
            self.name = name
            self.publicKey = publicKey
        }

        init?(_ url: URL) {
            guard url.scheme?.lowercased() == "amiscara-agents", url.host() == "pair-tv",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.first(where: { $0.name == "v" })?.value == "1",
                  let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty,
                  let key = items.first(where: { $0.name == "key" })?.value, key.hasPrefix("ssh-")
            else { return nil }
            tvID = id
            name = items.first(where: { $0.name == "name" })?.value ?? "Apple TV"
            publicKey = key
        }
    }

    /// What the TV needs to connect to a host; no secrets.
    struct Host: Codable, Equatable {
        let name: String
        let host: String
        let port: Int
        let user: String
        let socketPath: String
        let hostKey: String
    }

    // MARK: Proof that a code comes from the user's own TV

    /// The TV's public key, written into the user's private iCloud database
    /// while it shows its code. The iPhone pairs only when the key in a link
    /// matches this record: a crafted link from a message or web page has
    /// no such record, since nobody else can write the user's database.
    static let identityType = "TVIdentity"
    static let publicKeyField = "publicKey"

    private static func identityID(_ tvID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "tvkey-" + String(tvID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }))
    }

    static func publishIdentity(tvID: String, publicKey: String) async throws {
        let record = CKRecord(recordType: identityType, recordID: identityID(tvID))
        record[publicKeyField] = publicKey
        _ = try await CloudPush.container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// Whether `link` is a code the user's own TV shows.
    static func isGenuine(_ link: Link) async -> Bool {
        guard let record = try? await CloudPush.container.privateCloudDatabase.record(for: identityID(link.tvID)),
              let stored = record[publicKeyField] as? String
        else { return false }
        func keyPart(_ line: String) -> String { line.split(separator: " ").prefix(2).joined(separator: " ") }
        return keyPart(stored) == keyPart(link.publicKey)
    }

    // MARK: Addresses in the home network

    /// A host's Bonjour name (`mac.local`), keyed by its SSH host key
    /// fingerprint. The Mac app on the host writes it; the Apple TV, which
    /// has no VPN (no NetBird on tvOS), connects through it instead of the
    /// address the iPhone uses.
    static let addressType = "HostAddress"
    static let lanNameField = "lanName"

    private static func addressID(_ fingerprint: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "host-" + String(fingerprint.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }))
    }

    /// The Bonjour name the host's Mac app left, if any.
    static func lanName(forHostKey hostKey: String?) async -> String? {
        guard let fingerprint = CloudPush.hostKey(forPublicKey: hostKey) else { return nil }
        let record = try? await CloudPush.container.privateCloudDatabase.record(for: addressID(fingerprint))
        return (record?[lanNameField] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Leaves this Mac's Bonjour name for the Apple TV.
    static func publishLANName(_ name: String, hostKey fingerprint: String) async throws {
        let record = CKRecord(recordType: addressType, recordID: addressID(fingerprint))
        record[lanNameField] = name
        _ = try await CloudPush.container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    private static func recordID(_ tvID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "tv-" + String(tvID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }))
    }

    /// The hosts left for a TV so far.
    static func hosts(for tvID: String) async throws -> [Host] {
        do {
            let record = try await CloudPush.container.privateCloudDatabase.record(for: recordID(tvID))
            guard let json = record[hostsField] as? String else { return [] }
            return try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    /// Adds `hosts` to the TV's record (replacing entries for the same address).
    static func add(_ hosts: [Host], for tvID: String) async throws {
        let database = CloudPush.container.privateCloudDatabase
        let id = recordID(tvID)
        let record: CKRecord
        var merged: [Host]
        do {
            record = try await database.record(for: id)
            merged = (record[hostsField] as? String).flatMap { try? JSONDecoder().decode([Host].self, from: Data($0.utf8)) } ?? []
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: id)
            merged = []
        }
        for host in hosts {
            merged.removeAll { $0.host == host.host && $0.port == host.port && $0.user == host.user }
            merged.append(host)
        }
        record[hostsField] = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}

#if os(tvOS)
/// The TV's own SSH key, made once and kept in its Keychain.
enum TVKey {
    /// Keychain slot of the key, not a host id.
    static let slot = UUID(uuidString: "7A7E5E6C-0000-4000-8000-000000000127")!

    static func load() throws -> SshKey {
        if let pem = try KeyStore.load(for: slot) {
            return try describeSshKey(privateOpenssh: pem)
        }
        let key = try generateSshKey(comment: "amiscara-agents \(UIDevice.current.name)")
        try KeyStore.save(privateKey: key.privateOpenssh, for: slot)
        return key
    }

    static var tvID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "apple-tv"
    }
}

extension HostStore {
    /// Adds the hosts the iPhone left for this TV that it does not have yet.
    /// Returns how many were added.
    @discardableResult
    func adoptPairedHosts() async -> Int {
        guard let hosts = try? await TVPairing.hosts(for: TVKey.tvID), !hosts.isEmpty,
              let key = try? TVKey.load()
        else { return 0 }
        var added = 0
        for host in hosts where !connections.contains(where: {
            $0.config.pinnedHostKey == host.hostKey && $0.config.user == host.user
        }) {
            var config = HostConfig(name: host.name, kind: .ssh)
            // The TV has no VPN: the host's name in the home network first.
            config.host = await TVPairing.lanName(forHostKey: host.hostKey) ?? host.host
            config.port = host.port
            config.user = host.user
            config.socketPath = host.socketPath
            config.pinnedHostKey = host.hostKey
            config.publicKey = key.publicOpenssh
            guard (try? KeyStore.save(privateKey: key.privateOpenssh, for: config.id)) != nil else { continue }
            add(config)
            added += 1
        }
        return added
    }

    /// Switches hosts to the Bonjour name their Mac app published, e.g. for
    /// hosts paired before the name was known.
    func useHomeNetworkAddresses() async {
        for connection in connections where connection.config.kind == .ssh {
            guard let lan = await TVPairing.lanName(forHostKey: connection.config.pinnedHostKey),
                  lan != connection.config.host
            else { continue }
            var config = connection.config
            config.host = lan
            update(config)
        }
    }
}
#endif

#if os(macOS)
import SystemConfiguration

extension HostStore {
    /// Leaves this Mac's Bonjour name (`<LocalHostName>.local`) under its SSH
    /// host key in iCloud, for Apple TVs that cannot use the VPN address.
    func publishHomeNetworkName() async {
        guard !DemoMode.isOn, let fingerprint = cloudPush.hostKey,
              let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty
        else { return }
        try? await TVPairing.publishLANName("\(local).local", hostKey: fingerprint)
    }
}
#endif
