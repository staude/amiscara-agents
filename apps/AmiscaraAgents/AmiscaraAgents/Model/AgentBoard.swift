import Foundation

/// How the overview shows the agents (#345).
enum OverviewLayout: String, CaseIterable {
    case list, board

    static let storageKey = "overviewLayout"
}

/// The overview as a board (#345): one column per state, waiting, working,
/// done, so also an empty state shows its column. Like the list it has no
/// idle column. A pinned agent (#334) stays in the column of its state, at
/// the top; a pinned one that is ready or unknown, which the list shows too,
/// goes to the last column. No FFI types in here, so the tests build it without the core.
struct AgentBoard: Equatable {
    struct Column: Equatable, Identifiable {
        let group: AgentOverview.Group
        let rows: [AgentOverview.Row]

        var id: AgentOverview.Group { group }
    }

    let columns: [Column]

    init(_ overview: AgentOverview) {
        let rows = overview.sections.flatMap(\.rows)
        columns = [AgentOverview.Group.waiting, .working, .done].map { group in
            let inState = rows.filter { (AgentOverview.Group($0.agent.state) ?? ($0.pinned ? .done : nil)) == group }
            return Column(group: group, rows: inState.filter(\.pinned) + inState.filter { !$0.pinned })
        }
    }
}

/// When the board reads the screen of a card.
enum BoardRead {
    /// How often a working agent's screen is read again.
    static let refresh: TimeInterval = 30
    /// Lines shown on a card.
    static let lines = 3
    /// Lines read, so enough remain after the frame and footer are dropped.
    static let readLines: UInt32 = 30

    /// Whether the screen is due: never read, the state changed since, or
    /// the agent works and the last reading is `refresh` old. A waiting or
    /// done agent's screen stays as it is.
    static func due(state: WidgetSnapshot.State, last: (state: WidgetSnapshot.State, date: Date)?, now: Date) -> Bool {
        guard let last, last.state == state else { return true }
        return state == .working && now.timeIntervalSince(last.date) >= refresh
    }
}
