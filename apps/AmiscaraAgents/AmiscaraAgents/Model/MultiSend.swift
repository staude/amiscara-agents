import Foundation

/// One prompt to several agent panes (#299): which agents can be picked,
/// the quick selections and what came of each send. herdr refuses a prompt
/// to an agent waiting at a dialog, so waiting agents cannot be picked, nor
/// agents of hosts without a connection or with input off. No FFI types in
/// here, so the tests build it without the core.
enum MultiSend {
    /// An agent the prompt can go to.
    struct Target: Equatable, Identifiable {
        let hostID: UUID
        let hostName: String
        let paneID: String
        let name: String
        let place: String
        let state: WidgetSnapshot.State
        /// Why it cannot be picked; `nil` when it can.
        let blockedReason: String?

        var id: String { "\(hostID.uuidString)|\(paneID)" }

        init(hostID: UUID, hostName: String, agent: WidgetSnapshot.Agent, live: Bool, inputAllowed: Bool) {
            self.hostID = hostID
            self.hostName = hostName
            paneID = agent.paneID
            name = agent.name
            place = agent.place
            state = agent.state
            blockedReason = if agent.state == .blocked {
                String(localized: "Wartet auf Antwort")
            } else if !live {
                String(localized: "Keine Verbindung")
            } else if !inputAllowed {
                String(localized: "Eingabe aus")
            } else {
                nil
            }
        }

        var isSelectable: Bool { blockedReason == nil }
    }

    /// The quick selections; none for waiting agents, herdr refuses them.
    enum Preset: CaseIterable {
        case all, finished, working

        var title: String {
            switch self {
            case .all: String(localized: "Alle")
            case .finished: String(localized: "Alle fertigen")
            case .working: String(localized: "Alle arbeitenden")
            }
        }
    }

    /// The ids a quick selection picks, only from agents that can be picked:
    /// finished means done and ready, all includes unknown states.
    static func select(_ preset: Preset, in targets: [Target]) -> Set<String> {
        Set(targets.filter { target in
            guard target.isSelectable else { return false }
            return switch preset {
            case .all: true
            case .finished: target.state == .done || target.state == .idle
            case .working: target.state == .working
            }
        }.map(\.id))
    }

    enum Outcome: Equatable {
        case sent
        case skipped(String)
        case failed(String)
    }

    struct Result: Equatable, Identifiable {
        let target: Target
        let outcome: Outcome

        var id: String { target.id }
    }
}
