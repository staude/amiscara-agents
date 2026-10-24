import AppIntents
import Foundation
#if os(iOS)
import UIKit
#endif

// Shortcuts and Siri. The intents run in the app process and read the live
// HostStore the app registers with AppDependencyManager; none of them sends
// anything to herdr. Agent names, titles and hosts are private, so every
// intent needs an unlocked device and the query answers nothing while locked.

/// An agent pane on a host, as Shortcuts and Siri see it.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentQuery()

    /// "<host UUID>/<pane id>": pane ids are only unique per host.
    let id: String
    let hostID: UUID
    let workspaceID: String
    let paneID: String

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
            subtitle: "\(status) · \(host) · \(space) · Tab \(tab)"
        )
    }

    @MainActor
    init(_ item: BoardItem, on connection: HostConnection) {
        hostID = connection.id
        workspaceID = item.workspaceId
        paneID = item.paneId
        id = "\(connection.id.uuidString)/\(item.paneId)"
        name = item.agent.isEmpty ? String(localized: "Agent") : item.agent
        host = connection.config.name
        space = item.spacePlace
        tab = item.tabLabel
        status = item.agentState.label
        isWaiting = item.agentState == .blocked
    }
}

struct AgentQuery: EntityStringQuery {
    @Dependency private var store: HostStore

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        await store.agents().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentEntity] {
        await store.agents().filter { agent in
            [agent.name, agent.space, agent.host].contains { $0.localizedStandardContains(string) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        await store.agents()
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
        guard let last = LastAgent.current,
              let agent = await store.agents().first(where: { $0.hostID == last.hostID && $0.paneID == last.paneID })
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
struct LastAgent: Equatable {
    let hostID: UUID
    let paneID: String

    private static let hostKey = "lastAgentHost"
    private static let paneKey = "lastAgentPane"

    static var current: LastAgent? {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: hostKey).flatMap(UUID.init(uuidString:)),
              let pane = defaults.string(forKey: paneKey)
        else { return nil }
        return LastAgent(hostID: host, paneID: pane)
    }

    static func remember(host: UUID, pane: String) {
        guard !DemoMode.isOn else { return }
        UserDefaults.standard.set(host.uuidString, forKey: hostKey)
        UserDefaults.standard.set(pane, forKey: paneKey)
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
        while connection.isSettling, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connection.isLive else { throw PromptIntentError.unreachable(connection.config.name) }
        do {
            try await connection.submit(text, to: paneID, isAgent: true)
        } catch {
            throw PromptIntentError.failed(inputErrorMessage(error))
        }
        LastAgent.remember(host: hostID, pane: paneID)
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
        while connections.contains(where: \.isSettling), ContinuousClock.now < deadline {
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
