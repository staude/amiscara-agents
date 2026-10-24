#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The Live Activity of working and waiting agents (#224): one activity
/// for all hosts with up to three agents, waiting first. The app starts,
/// updates and ends it; the widget extension draws it.
struct AgentsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var agents: [Entry]
        var waiting: Int
        var working: Int
    }

    struct Entry: Codable, Hashable, Identifiable {
        let hostID: UUID
        let paneID: String
        let workspaceID: String
        /// The agent's custom name, else its kind.
        let name: String
        /// "Space · Tab".
        let place: String
        let state: WidgetSnapshot.State
        /// The last line of the pane's screen, when the app could read it.
        var line: String?

        var id: String { "\(hostID.uuidString)/\(paneID)" }
    }

    /// Agents shown at most; the Lock Screen has room for three rows.
    static let limit = 3
}

/// An answer button in the Live Activity. Runs in the app's process, which
/// sends the key like the answer buttons of a notification.
struct AnswerAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Agent antworten"
    static let isDiscoverable = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Host")
    var hostID: String
    @Parameter(title: "Pane")
    var paneID: String
    @Parameter(title: "Taste")
    var key: String

    init() {}

    init(hostID: UUID, paneID: String, key: String) {
        self.hostID = hostID.uuidString
        self.paneID = paneID
        self.key = key
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let host = UUID(uuidString: hostID), let answer = AgentActivityBridge.answer else { return .result() }
        _ = await answer(host, paneID, key)
        return .result()
    }
}

/// Set by the app; the widget extension only draws.
@MainActor
enum AgentActivityBridge {
    static var answer: (@MainActor (_ hostID: UUID, _ paneID: String, _ key: String) async -> Bool)?
}
#endif
