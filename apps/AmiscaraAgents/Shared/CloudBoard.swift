import CloudKit
import Foundation

/// The agents of one host as the Mac app on the host sees them, in the
/// user's private iCloud database (#156). One record per host key,
/// overwritten on every change, so devices that cannot reach the host (or
/// whose app is not running) still know who waits: the iPhone widgets, the
/// Apple TV and later the Watch. Shared by the apps and the widgets; no FFI
/// types in here.
struct CloudBoard: Equatable {
    /// Fingerprint of the host's SSH host key, as in `CloudPush`.
    let hostKey: String
    let hostName: String
    /// Whether the Mac was connected to the host when it wrote this.
    let live: Bool
    let updated: Date
    let agents: [WidgetSnapshot.Agent]

    static let containerID = "iCloud.net.staude.amiscara.agents"
    static let recordType = "HostBoard"

    enum Field {
        static let hostKey = "hostKey"
        static let hostName = "hostName"
        static let live = "live"
        static let updated = "updated"
        static let agents = "agents"
    }

    /// Older boards say nothing about now, e.g. when the Mac app quit; the
    /// Mac rewrites its boards at least every five minutes.
    static let maxAge: TimeInterval = 15 * 60

    static var database: CKDatabase {
        CKContainer(identifier: containerID).privateCloudDatabase
    }

    /// Record names allow letters, digits, `-` and `_`.
    static func recordID(hostKey: String) -> CKRecord.ID {
        let name = "\(recordType)-\(hostKey)".map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return CKRecord.ID(recordName: String(name))
    }

    var record: CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID(hostKey: hostKey))
        record[Field.hostKey] = hostKey
        record[Field.hostName] = hostName
        record[Field.live] = live
        record[Field.updated] = updated
        let json = (try? JSONEncoder().encode(agents)).flatMap { String(data: $0, encoding: .utf8) }
        record[Field.agents] = json ?? "[]"
        return record
    }

    init(hostKey: String, hostName: String, live: Bool, updated: Date, agents: [WidgetSnapshot.Agent]) {
        self.hostKey = hostKey
        self.hostName = hostName
        self.live = live
        self.updated = updated
        self.agents = agents
    }

    init?(record: CKRecord) {
        guard let hostKey = record[Field.hostKey] as? String,
              let updated = record[Field.updated] as? Date,
              let json = (record[Field.agents] as? String)?.data(using: .utf8),
              let agents = try? JSONDecoder().decode([WidgetSnapshot.Agent].self, from: json)
        else { return nil }
        self.hostKey = hostKey
        hostName = record[Field.hostName] as? String ?? ""
        live = (record[Field.live] as? Bool) ?? false
        self.updated = updated
        self.agents = agents
    }

    /// Same host state, whenever it was written.
    func sameContent(as other: CloudBoard) -> Bool {
        hostKey == other.hostKey && hostName == other.hostName && live == other.live && agents == other.agents
    }

    /// The boards of the given hosts; hosts without one are left out.
    /// Fetched by record name, so no query index is needed.
    static func fetch(hostKeys: [String]) async throws -> [CloudBoard] {
        let ids = Array(Set(hostKeys)).map { recordID(hostKey: $0) }
        guard !ids.isEmpty else { return [] }
        let results = try await database.records(for: ids)
        return results.values.compactMap { result in
            guard case .success(let record) = result else { return nil }
            return CloudBoard(record: record)
        }
    }
}

extension WidgetSnapshot {
    /// The snapshot with the agents of hosts this device has no fresh
    /// view of taken from the Mac's boards: a board wins when it is newer
    /// than the snapshot, or when the host is not connected here and the
    /// board is recent.
    func merging(_ boards: [CloudBoard], now: Date = .now) -> WidgetSnapshot {
        let byKey = Dictionary(boards.map { ($0.hostKey, $0) }, uniquingKeysWith: { $0.updated > $1.updated ? $0 : $1 })
        var newest = updated
        let merged = hosts.map { host -> Host in
            guard let key = host.hostKey, let board = byKey[key] else { return host }
            let recent = now.timeIntervalSince(board.updated) < CloudBoard.maxAge
            guard board.updated > updated || (!host.live && recent) else { return host }
            newest = max(newest, board.updated)
            return Host(id: host.id, name: host.name, live: board.live && recent, agents: board.agents, hostKey: key)
        }
        return WidgetSnapshot(updated: newest, hosts: merged)
    }
}
