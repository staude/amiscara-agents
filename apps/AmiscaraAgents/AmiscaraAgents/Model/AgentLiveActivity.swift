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
    /// False until the first update compared with what is on screen: an
    /// activity can outlive the app that started it.
    private var synced = false
    /// Changes go out one after another, in order.
    private var pending: Task<Void, Never>?
    /// When the activity last went out; unchanged content goes out again
    /// after `resend`, so its stale date moves on while agents keep waiting.
    private var sentAt = Date.distantPast
    private static let resend: TimeInterval = 4 * 60
    /// Last screen lines per agent and when and for which state they were
    /// read; dropped when the agent leaves the activity.
    private var lines: [String: String] = [:]
    private var linesRead: [String: (state: WidgetSnapshot.State, at: Date)] = [:]

    /// Without news an activity counts as outdated after this.
    private nonisolated static let staleAfter: TimeInterval = 15 * 60
    /// A working agent's line is read again after this.
    private static let lineRefresh: TimeInterval = 30

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
        let shownIDs = Set(state.agents.map(\.id))
        lines = lines.filter { shownIDs.contains($0.key) }
        linesRead = linesRead.filter { shownIDs.contains($0.key) }
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
        guard state != shown || !synced || Date.now.timeIntervalSince(sentAt) >= Self.resend else { return }
        shown = state
        synced = true
        sentAt = .now
        let previous = pending
        pending = Task {
            await previous?.value
            // iOS starts activities only while the app is in front; a start
            // from a background push fails and is tried again next time.
            if !(await Self.show(state)) {
                if self.shown == state { self.shown = nil }
            }
        }
    }

    /// Off the main actor: activities are not `Sendable`, so they are
    /// looked up where they are used. False when a start failed.
    private nonisolated static func show(_ state: AgentsActivityAttributes.ContentState?) async -> Bool {
        let all = Activity<AgentsActivityAttributes>.activities
        let running = all.filter { $0.activityState == .active || $0.activityState == .stale }
        // Ended by the system (after hours) or dismissed ones go.
        for old in all where old.activityState == .ended || old.activityState == .dismissed {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        guard let state else {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return true
        }
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(staleAfter))
        if let activity = running.first {
            await activity.update(content)
            // One activity is enough; a second may come from an older run.
            for extra in running.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            return true
        }
        return (try? Activity.request(attributes: AgentsActivityAttributes(), content: content)) != nil
    }

    /// Reads the last line of what each shown agent wrote: once per state,
    /// for a working agent again after `lineRefresh`, over the live
    /// connection; agents from iCloud boards stay without.
    private func readLines(for agents: [AgentsActivityAttributes.Entry], store: HostStore) {
        let now = Date.now
        let wanted = agents.filter { agent in
            guard let read = linesRead[agent.id] else { return true }
            return read.state != agent.state
                || (agent.state == .working && now.timeIntervalSince(read.at) >= Self.lineRefresh)
        }
        guard !wanted.isEmpty else { return }
        for agent in wanted { linesRead[agent.id] = (agent.state, now) }
        Task {
            var changed = false
            for agent in wanted {
                guard let connection = store.connection(for: agent.hostID), connection.isLive,
                      let excerpt = await connection.screenExcerpt(paneID: agent.paneID, lines: 30),
                      let line = Self.lastOutputLine(excerpt, waiting: agent.state == .blocked)
                else { continue }
                if lines[agent.id] != line {
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

    /// The line to show: for a waiting agent the last line of its question
    /// (what the answer buttons answer); for a working one its own last
    /// output, which Claude Code marks with ⏺ at the start of the row
    /// (indented tool output with a ⏺ does not count). Otherwise the last
    /// line that is not frame or the TUI's footer ("? for shortcuts", "esc
    /// to interrupt", mode hints).
    static func lastOutputLine(_ screen: String, waiting: Bool) -> String? {
        let raw = screen.split(separator: "\n")
        if !waiting, let marked = raw.last(where: { $0.hasPrefix("⏺") }) {
            return String(marked.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let rows = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        let footer = ["for shortcuts", "esc to", "accept edits", "bypass permissions", "plan mode", "⏵", "ctrl+"]
        return rows.last { row in
            !row.isEmpty
                && !row.allSatisfy { "─│╭╮╰╯>❯ ".contains($0) }
                && !footer.contains { row.localizedCaseInsensitiveContains($0) }
        }
    }
}
#endif
