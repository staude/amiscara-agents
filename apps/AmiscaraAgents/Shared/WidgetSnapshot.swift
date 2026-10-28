import Foundation

/// What the widgets show: the agents of all hosts as the app saw them last.
/// Widgets cannot hold an SSH session, so the app writes this into the App
/// Group container whenever the board changes and asks WidgetKit to reload.
/// Shared by the app and the widget extensions; no FFI types in here.
struct WidgetSnapshot: Codable, Equatable {
    var updated: Date
    var hosts: [Host]

    struct Host: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        /// Connected when the snapshot was written.
        let live: Bool
        let agents: [Agent]
        /// Fingerprint of the host's SSH host key, to match the Mac's
        /// boards in iCloud (`CloudBoard`); `nil` when unknown.
        var hostKey: String? = nil
    }

    struct Agent: Codable, Equatable, Identifiable {
        let paneID: String
        let workspaceID: String
        /// "Space · Tab" as in the sidebar.
        let place: String
        /// The agent's custom name, else its kind (`claude`).
        let name: String
        let state: State
        /// Since when the agent is in its state, as the app saw it change;
        /// `nil` when unknown, also in snapshots and boards from older builds.
        var since: Date? = nil

        var id: String { paneID }
    }

    enum State: String, Codable {
        case blocked, working, done, idle, unknown

        /// Waiting first, as on the board.
        var urgency: Int {
            switch self {
            case .blocked: 0
            case .working: 1
            case .done: 2
            case .idle: 3
            case .unknown: 4
            }
        }
    }

    static let empty = WidgetSnapshot(updated: .distantPast, hosts: [])

    /// All agents, waiting first, then by host order.
    var agents: [(host: Host, agent: Agent)] {
        hosts.flatMap { host in host.agents.map { (host: host, agent: $0) } }
            .enumerated()
            .sorted { ($0.element.agent.state.urgency, $0.offset) < ($1.element.agent.state.urgency, $1.offset) }
            .map(\.element)
    }

    func count(_ state: State) -> Int {
        hosts.reduce(0) { $0 + $1.agents.filter { $0.state == state }.count }
    }

    // MARK: Storage

    /// On the Mac a team-prefixed group needs no registration; iOS needs the
    /// `group.` form.
    #if os(macOS)
    static let appGroup = "7N2W4T6UPV.net.staude.amiscara.agents"
    #else
    static let appGroup = "group.net.staude.amiscara.agents"
    #endif

    /// The widget kind; the app reloads it after writing.
    static let widgetKind = "Agents"

    /// Where the snapshot and the Top Shelf cards live. tvOS lets apps write
    /// only below `Library/Caches`, also in an App Group container.
    static var directory: URL? {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #if os(tvOS)
        return container?.appending(path: "Library/Caches")
        #else
        return container
        #endif
    }

    private static var fileURL: URL? {
        directory?.appending(path: "widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    func save() throws {
        guard let url = Self.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: Links

    /// Opens the agent's pane in the app, like a tapped notification;
    /// `dictate` also starts dictation into its composer (#227).
    static func openURL(host: UUID, workspaceID: String, paneID: String, dictate: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = "amiscara-agents"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "host", value: host.uuidString),
            URLQueryItem(name: "space", value: workspaceID),
            URLQueryItem(name: "pane", value: paneID),
        ] + (dictate ? [URLQueryItem(name: "dictate", value: "1")] : [])
        return components.url!
    }

    /// Opens the app without a pane.
    static let appURL = URL(string: "amiscara-agents://open")!

    /// Whether an `openURL` link asks for dictation.
    static func wantsDictation(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "dictate" && $0.value == "1" } == true
    }

    // MARK: Last agent


    /// The pane the last prompt went to, for the controls (#227); the app
    /// keeps the full record (`LastAgent`).
    static let lastAgentKey = "lastAgentTarget"

    static func saveLastAgent(host: UUID, workspaceID: String, paneID: String) {
        UserDefaults(suiteName: appGroup)?.set([host.uuidString, workspaceID, paneID], forKey: lastAgentKey)
    }

    static func lastAgent() -> (host: UUID, workspaceID: String, paneID: String)? {
        guard let parts = UserDefaults(suiteName: appGroup)?.stringArray(forKey: lastAgentKey), parts.count == 3,
              let host = UUID(uuidString: parts[0])
        else { return nil }
        return (host, parts[1], parts[2])
    }

    /// The parts of an `openURL` link, or `nil` for any other URL.
    static func parseOpenURL(_ url: URL) -> (host: UUID, workspaceID: String, paneID: String)? {
        guard url.scheme?.lowercased() == "amiscara-agents", url.host() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value.flatMap(UUID.init(uuidString:)),
              let space = items.first(where: { $0.name == "space" })?.value,
              let pane = items.first(where: { $0.name == "pane" })?.value
        else { return nil }
        return (host, space, pane)
    }
}

/// The kinds of the Control Center controls (#227).
enum WaitingControlKind {
    static let waiting = "net.staude.amiscara.agents.control.waiting"
    static let dictate = "net.staude.amiscara.agents.control.dictate"
}

/// "Dictate to this pane" from a control (#227); stale after a minute, so
/// a pane that shows much later does not turn the microphone on by itself.
struct DictateRequest: Equatable, Sendable {
    let hostID: UUID
    let paneID: String
    let at: Date

    static let maxAge: TimeInterval = 60

    var isFresh: Bool { Date.now.timeIntervalSince(at) < Self.maxAge }
}
