import Foundation

/// The time a tab's agents have spent in their state, shown next to the tab
/// title (#338). Without FFI types, so scripts/agent-overview-test.sh can
/// build it on its own.
enum TabTime {
    /// Since when the tab's agents are in `state`: the earliest start of
    /// those in that state. An agent without a start of its own takes the
    /// Mac's board from iCloud, if it knows the same pane in the same
    /// state. Only working and waiting agents have a time; `nil` for the
    /// rest and when no start is known.
    static func since(
        state: WidgetSnapshot.State,
        agents: [WidgetSnapshot.Agent],
        board: CloudBoard?
    ) -> Date? {
        guard state == .working || state == .blocked else { return nil }
        return agents
            .filter { $0.state == state }
            .compactMap { agent in
                agent.since ?? board?.agents.first { $0.paneID == agent.paneID && $0.state == state }?.since
            }
            .min()
    }

    /// "12 Min." or "2 Std."; whole minutes under an hour, whole hours
    /// above, `nil` under a minute and for a start in the future.
    static func label(since: Date, now: Date, locale: Locale = .current) -> String? {
        let seconds = now.timeIntervalSince(since)
        guard seconds >= 60 else { return nil }
        let unit: Duration = seconds < 3600
            ? .seconds(Int(seconds / 60) * 60)
            : .seconds(Int(seconds / 3600) * 3600)
        return unit.formatted(
            .units(
                allowed: [.hours, .minutes],
                width: .abbreviated,
                maximumUnitCount: 1,
                fractionalPart: .hide(rounded: .down)
            )
            .locale(locale)
        )
    }
}
