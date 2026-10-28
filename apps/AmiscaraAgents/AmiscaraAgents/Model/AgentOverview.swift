import Foundation

/// The agents of all hosts on one page (#274), in three groups: waiting,
/// working, done. Agents that are ready or unknown need nothing from the
/// user and stay out. A host without a connection shows the newer of its
/// own last state and the Mac's board in iCloud, marked with its age. No
/// FFI types in here, so the tests build it without the core.
struct AgentOverview: Equatable {
    /// One host as the overview needs it.
    struct Host {
        let id: UUID
        let name: String
        let live: Bool
        /// When it last sent an update while connected.
        let liveAt: Date?
        /// Fingerprint of its SSH host key, to find its `CloudBoard`.
        let hostKey: String?
        /// Its agents as this device last saw them.
        let agents: [WidgetSnapshot.Agent]
    }

    enum Group: CaseIterable {
        case waiting, working, done

        init?(_ state: WidgetSnapshot.State) {
            switch state {
            case .blocked: self = .waiting
            case .working: self = .working
            case .done: self = .done
            case .idle, .unknown: return nil
            }
        }

        var title: String {
            switch self {
            case .waiting: String(localized: "Wartet auf dich")
            case .working: String(localized: "Arbeitet")
            case .done: String(localized: "Fertig")
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let hostID: UUID
        let hostName: String
        let agent: WidgetSnapshot.Agent
        /// Since when the agent is in its state; `nil` when unknown.
        var since: Date? { agent.since }
        /// For a host without a connection: how old the shown state is.
        let staleAt: Date?

        var id: String { "\(hostID.uuidString)|\(agent.paneID)" }
    }

    struct Section: Equatable, Identifiable {
        let group: Group
        let rows: [Row]

        var id: Group { group }
    }

    /// Only groups with agents, in the order waiting, working, done.
    let sections: [Section]

    var isEmpty: Bool { sections.isEmpty }

    var waitingCount: Int {
        sections.first { $0.group == .waiting }?.rows.count ?? 0
    }

    init(hosts: [Host], boards: [CloudBoard]) {
        let newest = Dictionary(boards.map { ($0.hostKey, $0) }, uniquingKeysWith: { $0.updated > $1.updated ? $0 : $1 })
        var rows: [Row] = []
        for host in hosts {
            let board = host.hostKey.flatMap { newest[$0] }
            let agents: [WidgetSnapshot.Agent]
            let staleAt: Date?
            if host.live {
                agents = host.agents.map { agent in
                    guard agent.since == nil,
                          let known = board?.agents.first(where: { $0.paneID == agent.paneID && $0.state == agent.state })
                    else { return agent }
                    var agent = agent
                    agent.since = known.since
                    return agent
                }
                staleAt = nil
            } else if let board, host.liveAt.map({ board.updated > $0 }) ?? true {
                agents = board.agents
                staleAt = board.updated
            } else {
                agents = host.agents
                staleAt = host.liveAt
            }
            rows += agents.map { Row(hostID: host.id, hostName: host.name, agent: $0, staleAt: staleAt) }
        }
        // Newest first, unknown times last; otherwise host and board order.
        let sorted = rows.enumerated().sorted { a, b in
            switch (a.element.since, b.element.since) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        sections = Group.allCases.compactMap { group in
            let rows = sorted.filter { Group($0.agent.state) == group }
            return rows.isEmpty ? nil : Section(group: group, rows: rows)
        }
    }
}
