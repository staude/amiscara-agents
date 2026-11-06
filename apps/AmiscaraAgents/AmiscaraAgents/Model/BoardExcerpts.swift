#if !os(tvOS)
import Foundation

/// The last lines of the screen of every card on the board (#345). Read
/// only while the board is open, and only when due (`BoardRead.due`). A host
/// without a connection shows the last screen this device knows; that is
/// not counted as read, so the live screen follows once it connects.
@MainActor
@Observable
final class BoardExcerpts {
    /// The lines by `AgentOverview.Row.id`.
    private(set) var lines: [String: [String]] = [:]
    @ObservationIgnored private var lastRead: [String: (state: WidgetSnapshot.State, date: Date)] = [:]

    func refresh(_ rows: [AgentOverview.Row], store: HostStore) async {
        let ids = Set(rows.map(\.id))
        for id in lines.keys where !ids.contains(id) { lines[id] = nil }
        for id in lastRead.keys where !ids.contains(id) { lastRead[id] = nil }
        for row in rows {
            if Task.isCancelled { return }
            guard BoardRead.due(state: row.agent.state, last: lastRead[row.id], now: .now) else { continue }
            let paneID = row.agent.paneID
            if row.staleAt == nil, let connection = store.connection(for: row.hostID), connection.isLive {
                if let screen = await connection.screenExcerpt(paneID: paneID, lines: BoardRead.readLines) {
                    lines[row.id] = ScreenLines.last(BoardRead.lines, of: screen)
                    lastRead[row.id] = (row.agent.state, .now)
                }
                // A failed read stays due and is tried again.
            } else if let entry = PaneCache.shared.entry(host: row.hostID, pane: paneID) {
                lines[row.id] = ScreenLines.last(BoardRead.lines, of: entry.content.plainText)
            } else {
                lines[row.id] = nil
            }
        }
    }
}
#endif
