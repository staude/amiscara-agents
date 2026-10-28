import AppIntents
import Foundation
#if os(iOS)
import CloudKit
import UIKit
import WidgetKit
#endif

// Shortcuts and Siri. The intents run in the app process and read the live
// HostStore the app registers with AppDependencyManager; on iOS, agents of
// hosts out of reach come from the widgets' snapshot and the Mac's boards
// (#275). Only the prompt intents (#226) send to herdr, with the composer's
// checks. Agent names,
// titles and hosts are private, so every intent needs an unlocked device
// and the query answers nothing while locked.

/// An agent pane on a host, as Shortcuts and Siri see it.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentQuery()

    /// "<host UUID>/<pane id>": pane ids are only unique per host.
    let id: String
    let hostID: UUID
    let workspaceID: String
    let paneID: String
    /// The space's name alone, which Siri also takes for the agent: many
    /// agents share a name such as "claude" (#275).
    let spaceName: String

    @Property(title: "Name")
    var name: String
    @Property(title: "Host")
    var host: String
    @Property(title: "Space")
    var space: String
    @Property(title: "Tab")
    var tab: String
    @Property(title: "Status")
    var status: String
    @Property(title: "Wartet")
    var isWaiting: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: tab.isEmpty ? "\(status) · \(host) · \(space)" : "\(status) · \(host) · \(space) · Tab \(tab)",
            synonyms: spaceName.isEmpty ? [] : ["\(spaceName)"]
        )
    }

    @MainActor
    init(_ item: BoardItem, on connection: HostConnection) {
        hostID = connection.id
        workspaceID = item.workspaceId
        paneID = item.paneId
        spaceName = item.workspaceName
        id = "\(connection.id.uuidString)/\(item.paneId)"
        name = item.agent.isEmpty ? String(localized: "Agent") : item.agent
        host = connection.config.name
        space = item.spacePlace
        tab = item.tabLabel
        status = item.agentState.label
        isWaiting = item.agentState == .blocked
    }

    /// An agent of a host this device cannot reach, as the widgets last
    /// saw it, often from the Mac's board (#275). Its place already holds
    /// the tab.
    init(host: WidgetSnapshot.Host, agent: WidgetSnapshot.Agent) {
        hostID = host.id
        workspaceID = agent.workspaceID
        paneID = agent.paneID
        spaceName = agent.place.components(separatedBy: " · ").first ?? agent.place
        id = "\(host.id.uuidString)/\(agent.paneID)"
        name = agent.name.isEmpty ? String(localized: "Agent") : agent.name
        self.host = host.name
        space = agent.place
        tab = ""
        status = agent.state.label
        isWaiting = agent.state == .blocked
    }
}

struct AgentQuery: EntityStringQuery {
    @Dependency private var store: HostStore

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        await store.knownAgents().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentEntity] {
        await store.knownAgents().filter { agent in
            [agent.name, agent.space, agent.host].contains { $0.localizedStandardContains(string) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        await store.knownAgents()
    }
}

/// "Welche Agents warten?": a spoken and written summary, plus the agents
/// as a result for further steps in a shortcut.
struct WaitingAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Welche Agents warten?"
    static let description = IntentDescription("Nennt die Agents, die auf eine Antwort warten, über alle Hosts.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Dependency private var store: HostStore

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AgentEntity]> & ProvidesDialog {
        let waiting = await store.agents().filter(\.isWaiting)
        let offline = store.unreachableHostNames
        var text: String
        switch waiting.count {
        case 0:
            text = String(localized: "Kein Agent wartet.")
        case 1:
            text = String(localized: "Ein Agent wartet: \(Self.phrase(waiting[0])).")
        default:
            let list = waiting.map(Self.phrase).formatted(.list(type: .and))
            text = String(localized: "\(waiting.count) Agents warten: \(list).")
        }
        if !offline.isEmpty {
            let hosts = offline.formatted(.list(type: .and))
            text += " " + String(localized: "Nicht erreichbar: \(hosts).")
        }
        return .result(value: waiting, dialog: IntentDialog(stringLiteral: text))
    }

    private static func phrase(_ agent: AgentEntity) -> String {
        String(localized: "\(agent.name) in \(agent.space)")
    }
}

/// "Öffne Agent …": opens the app on that agent's pane.
struct OpenAgentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Agent öffnen"
    static let description = IntentDescription("Öffnet Amiscara Agents beim gewählten Agent.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Agent")
    var target: AgentEntity

    @Dependency private var store: HostStore

    @MainActor
    func perform() async throws -> some IntentResult {
        // The window takes the request like a tapped notification.
        store.notifier.openRequest = SpaceRef(
            hostID: target.hostID,
            workspaceID: target.workspaceID,
            paneID: target.paneID
        )
        return .result()
    }
}

/// "Sag Claude im Shop: …" (#226): a prompt to an agent, as the composer
/// sends it. Siri asks for the agent and the text when they are missing.
struct SendPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Prompt an Agent senden"
    static let description = IntentDescription("Schickt einen Prompt an den gewählten Agent, wie das Eingabefeld der App.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Agent", requestValueDialog: "An welchen Agent?")
    var target: AgentEntity

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "Was soll ich senden?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$prompt) an \(\.$target) senden")
    }

    @Dependency private var store: HostStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await store.sendPrompt(prompt, toHost: target.hostID, pane: target.paneID)
        return .result(dialog: "Gesendet an \(target.name).")
    }
}

/// "Was macht Claude in Amiscara Agents?" (#275): status, since when and
/// the last screen lines of one agent, also as text for further steps.
struct AgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Was macht der Agent?"
    static let description = IntentDescription("Nennt Status, Dauer und die letzten Bildschirmzeilen eines Agents.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Agent", requestValueDialog: "Welcher Agent?")
    var target: AgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Was macht \(\.$target)?")
    }

    @Dependency private var store: HostStore

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await store.statusText(for: target)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// The same for the Action button: to the agent the last prompt went to,
/// from the app or from Siri.
struct SendPromptToLastAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Prompt an letzten Agent senden"
    static let description = IntentDescription("Schickt einen Prompt an den Agent, an den zuletzt ein Prompt ging.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "Was soll ich senden?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$prompt) an den letzten Agent senden")
    }

    @Dependency private var store: HostStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Pane ids are positions and come back for other agents (a new
        // space, a restarted server): the agent must still be the same.
        guard let last = LastAgent.current,
              let agent = await store.agents().first(where: { $0.hostID == last.hostID && $0.paneID == last.paneID }),
              last.matches(store.boardItem(host: agent.hostID, pane: agent.paneID))
        else { throw PromptIntentError.noLastAgent }
        try await store.sendPrompt(prompt, toHost: agent.hostID, pane: agent.paneID)
        return .result(dialog: "Gesendet an \(agent.name).")
    }
}

enum PromptIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt
    case noLastAgent
    case hostGone
    case unreachable(String)
    case inputOff(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt: "Der Prompt ist leer."
        case .noLastAgent: "Es gibt noch keinen letzten Agent, oder er läuft nicht mehr. Senden Sie einmal aus der App."
        case .hostGone: "Der Host dieses Agents ist auf diesem Gerät nicht eingerichtet."
        case .unreachable(let host): "\(host) ist gerade nicht erreichbar."
        case .inputOff(let host): "Eingaben sind für \(host) ausgeschaltet."
        case .failed(let message): "Senden fehlgeschlagen: \(message)"
        }
    }
}

/// The agent pane the last prompt went to, for the "last agent" intent
/// and control (#226, #227). Kept on this device.
struct LastAgent: Codable, Equatable {
    let hostID: UUID
    let paneID: String
    /// Who was in the pane: its space (id and label, ids are positions
    /// too), working directory, agent kind and name.
    let workspaceID: String
    let workspaceLabel: String
    let cwd: String?
    let agent: String
    let name: String?

    private static let key = "lastAgent"

    static var current: LastAgent? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastAgent.self, from: $0) }
    }

    /// Still the same agent in that pane.
    func matches(_ item: BoardItem?) -> Bool {
        guard let item else { return false }
        return item.workspaceId == workspaceID && item.workspaceLabel == workspaceLabel
            && item.cwd == cwd && item.agent == agent && item.name == name
    }

    @MainActor
    static func remember(_ item: BoardItem, on host: UUID) {
        guard !DemoMode.isOn else { return }
        let last = LastAgent(
            hostID: host,
            paneID: item.paneId,
            workspaceID: item.workspaceId,
            workspaceLabel: item.workspaceLabel,
            cwd: item.cwd,
            agent: item.agent,
            name: item.name
        )
        UserDefaults.standard.set(try? JSONEncoder().encode(last), forKey: key)
        // For the "dictate to the last agent" control (#227).
        WidgetSnapshot.saveLastAgent(host: host, workspaceID: item.workspaceId, paneID: item.paneId)
        #if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: WaitingControlKind.dictate)
        #endif
    }
}

struct HerdrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WaitingAgentsIntent(),
            phrases: [
                "Welche Agents warten in \(.applicationName)?",
                "Wartende Agents in \(.applicationName)",
                "Frag \(.applicationName), welche Agents warten",
            ],
            shortTitle: "Wartende Agents",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: OpenAgentIntent(),
            phrases: [
                "Öffne Agent in \(.applicationName)",
                "Agent in \(.applicationName) öffnen",
            ],
            shortTitle: "Agent öffnen",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: AgentStatusIntent(),
            phrases: [
                "Was macht \(\.$target) in \(.applicationName)?",
                "Was macht ein Agent in \(.applicationName)?",
            ],
            shortTitle: "Was macht der Agent?",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: SendPromptIntent(),
            phrases: [
                "Prompt an Agent in \(.applicationName) senden",
                "Sag einem Agent in \(.applicationName) etwas",
            ],
            shortTitle: "Prompt senden",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: SendPromptToLastAgentIntent(),
            phrases: [
                "Sag dem letzten Agent in \(.applicationName) etwas",
                "Prompt an letzten Agent in \(.applicationName)",
            ],
            shortTitle: "An letzten Agent",
            systemImageName: "paperplane.circle"
        )
    }
}

extension HostStore {
    /// Sends a prompt as the composer does, after the same checks.
    func sendPrompt(_ prompt: String, toHost hostID: UUID, pane paneID: String) async throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PromptIntentError.emptyPrompt }
        guard let connection = connection(for: hostID) else { throw PromptIntentError.hostGone }
        guard connection.config.inputAllowed else { throw PromptIntentError.inputOff(connection.config.name) }
        reconnectStale()
        let deadline = ContinuousClock.now + .seconds(6)
        while connection.isSettling, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connection.isLive else { throw PromptIntentError.unreachable(connection.config.name) }
        do {
            try await connection.submit(text, to: paneID, isAgent: true)
        } catch {
            throw PromptIntentError.failed(inputErrorMessage(error))
        }
        if let item = boardItem(host: hostID, pane: paneID) {
            LastAgent.remember(item, on: hostID)
        }
    }

    /// The agent in a pane as the board shows it.
    func boardItem(host hostID: UUID, pane paneID: String) -> BoardItem? {
        connection(for: hostID)?.update?.board.first { $0.paneId == paneID }
    }

    /// All agents on live hosts, waiting ones first. Waits briefly for hosts
    /// still connecting: an intent may have just launched or woken the app,
    /// and an empty board then would be a wrong answer.
    func agents() async -> [AgentEntity] {
        // Entity queries can run for suggestions before any intent asks
        // for authentication; a locked device gets nothing.
        guard Platform.isUnlocked else { return [] }
        reconnectStale()
        let deadline = ContinuousClock.now + .seconds(6)
        while connections.contains(where: \.isSettling), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return connections
            .filter { $0.isLive }
            .flatMap { connection in
                (connection.update?.board ?? []).map { (connection: connection, item: $0) }
            }
            .sorted { $0.item.agentState.urgency < $1.item.agentState.urgency }
            .map { AgentEntity($0.item, on: $0.connection) }
    }

    /// `agents()`, and on iOS also the agents of hosts that are not live,
    /// as the widgets last saw them (#275), so Siri and Shortcuts can name
    /// them. Locked, there are none, as in `agents()`.
    func knownAgents() async -> [AgentEntity] {
        guard Platform.isUnlocked else { return [] }
        let live = await agents()
        #if os(iOS)
        let liveHosts = Set(connections.filter(\.isLive).map(\.id))
        let configured = Set(connections.map(\.id))
        let others = WidgetSnapshot.load().agents
            .filter { configured.contains($0.host.id) && !liveHosts.contains($0.host.id) }
            .map { AgentEntity(host: $0.host, agent: $0.agent) }
        return live + others
        #else
        return live
        #endif
    }

    /// Tells Siri the agents again when one came, went or was renamed, so
    /// it understands their names in the phrases (#275). Takes the widgets'
    /// snapshot, which also holds the Mac's boards and loses removed hosts.
    /// At most once a minute: Siri then asks for the agents, and that
    /// reconnects hosts that are not live.
    func updateShortcutAgents(_ snapshot: WidgetSnapshot) {
        // Name and space are what Siri understands; tabs do not count.
        shortcutAgentsSeen = Set(snapshot.hosts.flatMap { host in
            host.agents.map { agent in
                let space = agent.place.components(separatedBy: " · ").first ?? agent.place
                return "\(host.id)/\(agent.paneID)|\(agent.name)|\(space)"
            }
        })
        guard shortcutPause == nil else { return }
        sendShortcutAgents()
    }

    /// Sends the agents seen when they changed, then pauses a minute and
    /// sends what changed meanwhile.
    private func sendShortcutAgents() {
        guard shortcutAgentsSeen != shortcutAgentsSent else {
            shortcutPause = nil
            return
        }
        shortcutAgentsSent = shortcutAgentsSeen
        HerdrShortcuts.updateAppShortcutParameters()
        shortcutPause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.sendShortcutAgents()
        }
    }

    /// The answer to "Was macht der Agent?" (#275): from the live
    /// connection, else (iOS) from the Mac's board in iCloud, else a
    /// message that there is nothing to say. Never fails.
    func statusText(for agent: AgentEntity) async -> String {
        let noData = AgentStatusText.noData(name: agent.name)
        guard let connection = connection(for: agent.hostID) else { return noData }
        reconnectStale()
        let deadline = ContinuousClock.now + .seconds(6)
        while connection.isSettling, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #if os(iOS)
        let hostKey = CloudPush.hostKey(forPublicKey: connection.config.pinnedHostKey)
        #endif
        if connection.isLive {
            guard let item = connection.update?.board.first(where: { $0.paneId == agent.paneID }) else { return noData }
            let state = WidgetSnapshot.State(item.agentState)
            let entry = connection.clock.entry(item.paneId).flatMap { $0.state == state ? $0 : nil }
            var since = entry?.since
            var exact = entry?.exact ?? false
            #if os(iOS)
            // The Mac may have seen the state begin when this device did not.
            if !exact, let hostKey, let board = await Self.macBoard(hostKey: hostKey),
               let seen = board.agents.first(where: { $0.paneID == item.paneId }),
               seen.state == state, let macSince = seen.since, macSince < since ?? .distantFuture {
                since = macSince
                exact = true
            }
            #endif
            let screen = await connection.screenExcerpt(paneID: item.paneId, lines: 30) ?? ""
            return AgentStatusText.text(
                name: agent.name,
                space: item.spacePlace,
                status: state.label,
                since: since,
                exact: exact,
                now: .now,
                lines: ScreenLines.last(3, of: screen),
                source: .live,
                linesMissingOffline: false
            )
        }
        #if os(iOS)
        guard let hostKey, let board = await Self.macBoard(hostKey: hostKey),
              let seen = board.agents.first(where: { $0.paneID == agent.paneID })
        else { return noData }
        // Lines only for a waiting agent: the Mac leaves them in its
        // "wartet" record for the Watch (#156); the record stays after.
        var lines: [String] = []
        if seen.state == .blocked,
           let excerpt = await Self.waitingExcerpt(hostKey: hostKey, paneID: seen.paneID, since: seen.since) {
            lines = ScreenLines.last(3, of: excerpt)
        }
        return AgentStatusText.text(
            name: agent.name,
            space: seen.place,
            status: seen.state.label,
            since: seen.since,
            exact: seen.since != nil,
            now: .now,
            lines: lines,
            source: .mac(updated: board.updated),
            linesMissingOffline: seen.state != .blocked
        )
        #else
        // The Mac app is the one writing the boards; it never reads them.
        return noData
        #endif
    }

    #if os(iOS)
    /// The Mac's board of a host, when it is recent and the Mac was
    /// connected to the host; `nil` otherwise or when iCloud fails.
    private static func macBoard(hostKey: String) async -> CloudBoard? {
        guard let board = try? await CloudBoard.fetch(hostKeys: [hostKey]).first,
              board.live, Date.now.timeIntervalSince(board.updated) < CloudBoard.maxAge
        else { return nil }
        return board
    }

    /// What a waiting agent asks, from its "wartet" record in iCloud; not
    /// from a record older than the waiting that began at `since`, which
    /// would be an earlier question. The Mac writes the record a moment
    /// after it sees the state; without `since` it did not see the waiting
    /// begin and may have written no record for it.
    private static func waitingExcerpt(hostKey: String, paneID: String, since: Date?) async -> String? {
        guard let since else { return nil }
        let id = CKRecord.ID(recordName: CloudPush.recordName(CloudPush.waitingType, hostKey, paneID))
        guard let record = try? await CloudPush.container.privateCloudDatabase.record(for: id),
              let text = record[CloudPush.Field.excerpt] as? String, !text.isEmpty
        else { return nil }
        guard let written = record.modificationDate, written >= since.addingTimeInterval(-60) else { return nil }
        return text
    }
    #endif

    /// Hosts whose agents an answer cannot include.
    var unreachableHostNames: [String] {
        connections.filter { !$0.isLive }.map(\.config.name)
    }
}

extension HostConnection {
    /// Still on the way to a first snapshot, as opposed to live or given up.
    var isSettling: Bool {
        guard startError == nil else { return false }
        switch status {
        case nil, .connecting, .retrying: return true
        case .live: return update?.serverVersion == nil
        case .hostKeyUnknown, .hostKeyChanged, .failed: return false
        }
    }
}

extension Platform {
    /// False while an iPhone or iPad with a passcode is locked.
    @MainActor
    static var isUnlocked: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}
