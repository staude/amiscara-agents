import Foundation

/// One Spotlight result for a space or an agent (#308), without any
/// CoreSpotlight type so the entries can be built and tested without it.
struct SpotlightEntry: Equatable {
    /// The link an opened result jumps to, also its unique identifier.
    let id: String
    let hostID: UUID
    let title: String
    let detail: String
    let keywords: [String]
}

enum SpotlightEntries {
    /// A space's fields for indexing, decoupled from the generated
    /// `WorkspaceItem` so this file depends on nothing but `WidgetSnapshot`.
    struct Space {
        let workspaceID: String
        let name: String
        let label: String
        let branch: String?
    }

    /// Per host and kind, so one very large host does not crowd out others.
    static let limit = 100

    /// Spaces, then agents, each the first `limit` in the given order.
    static func entries(hostID: UUID, hostName: String, spaces: [Space], agents: [WidgetSnapshot.Agent]) -> [SpotlightEntry] {
        let spaceEntries = spaces.prefix(limit).map { space in
            SpotlightEntry(
                id: WidgetSnapshot.spaceURL(host: hostID, workspaceID: space.workspaceID).absoluteString,
                hostID: hostID,
                title: space.name,
                detail: space.branch.map { "\(hostName) · \($0)" } ?? hostName,
                keywords: [space.label, space.branch, hostName].compactMap { $0 }
            )
        }
        let agentEntries = agents.prefix(limit).map { agent in
            SpotlightEntry(
                id: WidgetSnapshot.openURL(host: hostID, workspaceID: agent.workspaceID, paneID: agent.paneID).absoluteString,
                hostID: hostID,
                title: agent.name,
                detail: "\(agent.state.label) · \(agent.place) · \(hostName)",
                keywords: [agent.name, hostName]
            )
        }
        return Array(spaceEntries) + Array(agentEntries)
    }
}
