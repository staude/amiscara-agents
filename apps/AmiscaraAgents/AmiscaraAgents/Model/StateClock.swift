import Foundation

/// Since when each agent pane is in its state (#275). herdr reports no
/// time, so the app notes when it sees a state begin. A state seen first,
/// or first after a gap in the updates, may be older than that: then
/// `exact` is false and `since` is only the latest time it can have begun.
struct StateClock {
    struct Entry: Equatable {
        let state: WidgetSnapshot.State
        let since: Date
        let exact: Bool
    }

    private var entries: [String: Entry] = [:]

    /// Takes the states of all panes at `time`; `continuous` when the
    /// previous update came without a gap, so a change happened just now.
    /// Panes that are gone are forgotten.
    mutating func observe(_ panes: [(paneID: String, state: WidgetSnapshot.State)], at time: Date, continuous: Bool) {
        var next: [String: Entry] = [:]
        for pane in panes {
            if let old = entries[pane.paneID], old.state == pane.state {
                next[pane.paneID] = old
            } else {
                next[pane.paneID] = Entry(state: pane.state, since: time, exact: continuous)
            }
        }
        entries = next
    }

    func entry(_ paneID: String) -> Entry? {
        entries[paneID]
    }
}
