#if os(iOS)
import ActivityKit
import Foundation

/// Starts, updates and ends the Live Activity of working and waiting
/// agents (#224) from the board the widgets get: the live hosts while the
/// app runs, the Mac's boards in iCloud after a silent push. iOS rations
/// those pushes, so in the background it can lag behind.
@MainActor
final class AgentLiveActivity {
    static let shared = AgentLiveActivity()

    static let enabledKey = "liveActivity"

    /// On unless turned off in the settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var shown: AgentsActivityAttributes.ContentState?
    /// Last screen lines per agent, read once per state change.
    private var lines: [String: String] = [:]
    private var linesFor: [String: WidgetSnapshot.State] = [:]

    /// Without news an activity counts as outdated after this.
    private nonisolated static let staleAfter: TimeInterval = 15 * 60

    func update(_ snapshot: WidgetSnapshot, store: HostStore) {
        // Like notifications: only hosts that may show their agents (the
        // demo host has notifications off).
        let entries = snapshot.agents
            .filter { $0.agent.state == .blocked || $0.agent.state == .working }
            .filter { DemoMode.isOn || (store.connection(for: $0.host.id)?.config.notificationsOn ?? false) }
            .map { pair in
                AgentsActivityAttributes.Entry(
                    hostID: pair.host.id,
                    paneID: pair.agent.paneID,
                    workspaceID: pair.agent.workspaceID,
                    name: pair.agent.name,
                    place: pair.agent.place,
                    state: pair.agent.state
                )
            }
        var state = AgentsActivityAttributes.ContentState(
            agents: Array(entries.prefix(AgentsActivityAttributes.limit)),
            waiting: entries.filter { $0.state == .blocked }.count,
            working: entries.filter { $0.state == .working }.count
        )
        for index in state.agents.indices {
            state.agents[index].line = lines[state.agents[index].id]
        }
        apply(state)
        readLines(for: state.agents, store: store)
    }

    /// Turning the setting off ends the activity at once.
    func settingChanged(store: HostStore) {
        if Self.isEnabled {
            store.widgets.publish(store, force: true)
        } else {
            apply(nil)
        }
    }

    private func apply(_ state: AgentsActivityAttributes.ContentState?) {
        let state = Self.isEnabled && ActivityAuthorizationInfo().areActivitiesEnabled
            ? state.flatMap { $0.agents.isEmpty ? nil : $0 } : nil
        guard state != shown else { return }
        shown = state
        Task { await Self.show(state) }
    }

    /// Off the main actor: activities are not `Sendable`, so they are
    /// looked up where they are used.
    private nonisolated static func show(_ state: AgentsActivityAttributes.ContentState?) async {
        let running = Activity<AgentsActivityAttributes>.activities
        guard let state else {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(staleAfter))
        if let activity = running.first {
            await activity.update(content)
            // One activity is enough; a second may come from an older run.
            for extra in running.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        } else {
            _ = try? Activity.request(attributes: AgentsActivityAttributes(), content: content)
        }
    }

    /// Reads the last line of each shown agent's screen once per state,
    /// over the live connection; agents from iCloud boards stay without.
    private func readLines(for agents: [AgentsActivityAttributes.Entry], store: HostStore) {
        let wanted = agents.filter { linesFor[$0.id] != $0.state }
        guard !wanted.isEmpty else { return }
        for agent in wanted { linesFor[agent.id] = agent.state }
        Task {
            var changed = false
            for agent in wanted {
                guard let connection = store.connection(for: agent.hostID), connection.isLive,
                      let excerpt = await connection.screenExcerpt(paneID: agent.paneID, lines: 6)
                else { continue }
                let line = excerpt.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty && !$0.allSatisfy { "─│╭╮╰╯>❯ ".contains($0) } }
                if let line, lines[agent.id] != line {
                    lines[agent.id] = line
                    changed = true
                }
            }
            if changed, var state = shown {
                for index in state.agents.indices {
                    state.agents[index].line = lines[state.agents[index].id]
                }
                apply(state)
            }
        }
    }
}
#endif
