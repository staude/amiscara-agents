import Foundation
import Observation

#if !os(tvOS)
/// A full-text search across the Claude conversations of one host (#303).
/// Index-free: every search scans the session files on the host, so it
/// shows its progress and can be cancelled. Hits arrive piecewise.
@MainActor
@Observable
final class ConversationSearch {
    /// The text of the search shown.
    private(set) var query = ""
    private(set) var hits: [Found] = []
    /// Steps done and in all; `nil` until the search knows.
    private(set) var progress: (done: UInt64, total: UInt64)?
    private(set) var running = false
    private(set) var end: SearchEnd?
    private(set) var error: String?
    @ObservationIgnored private var handle: ConversationSearchHandle?
    /// Counts searches, so late callbacks of an earlier one are dropped.
    @ObservationIgnored private var generation = 0

    /// A hit with an id for lists; one line can hold several.
    struct Found: Identifiable {
        let id: Int
        let hit: ConversationHit
        let date: Date?
    }

    /// Whether there is a search to show: running or ended.
    var started: Bool { running || end != nil || error != nil }

    /// Starts searching `text` on `connection`; a running search ends.
    func start(_ text: String, on connection: HostConnection) {
        reset()
        let current = generation
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridge = SearchBridge { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.receive(event)
            }
        }
        do {
            handle = try connection.searchConversations(query: query, observer: bridge)
            running = true
        } catch FfiError.Rejected {
            self.error = String(localized: "Bitte mindestens zwei Zeichen auf einer Zeile suchen.")
        } catch {
            self.error = inputErrorMessage(error)
        }
    }

    /// Ends a running search; what it found so far stays.
    func cancel() {
        guard running else { return }
        handle?.cancel()
        handle = nil
        generation += 1
        running = false
        end = SearchEnd(error: nil, cancelled: true, truncated: false, olderSkipped: false)
    }

    /// Back to no search, e.g. for an empty search field.
    func clear() {
        reset()
        query = ""
    }

    private func reset() {
        handle?.cancel()
        handle = nil
        generation += 1
        running = false
        hits = []
        progress = nil
        end = nil
        error = nil
    }

    private func receive(_ event: SearchBridge.Event) {
        switch event {
        case .progress(let done, let total):
            progress = (done, total)
        case .hits(let found):
            let first = hits.count
            hits += found.enumerated().map { index, hit in
                Found(id: first + index, hit: hit, date: claudeDate(hit.timestamp))
            }
        case .finished(let end):
            running = false
            handle = nil
            self.end = end
            if let message = end.error {
                error = String(localized: "Suche fehlgeschlagen: \(message)")
            }
        }
    }

    /// One space with its sessions, newest first.
    struct SpaceGroup: Identifiable {
        let id: String
        let workspaceID: String?
        /// The conversation's directory, shown when no space is open for it.
        let cwd: String?
        let sessions: [SessionGroup]
    }

    /// One session file with its hits, newest first.
    struct SessionGroup: Identifiable {
        var id: String { sessionPath }
        let sessionPath: String
        let title: String?
        let hits: [Found]
        var newest: Date? { hits.first?.date }
    }

    /// The hits by space, then by session; groups with the newest hit
    /// first. Hits without an open space group by their directory.
    var groups: [SpaceGroup] {
        let newestFirst: (Date?, Date?) -> Bool = { ($0 ?? .distantPast) > ($1 ?? .distantPast) }
        let bySpace = Dictionary(grouping: hits) { found in
            found.hit.workspaceId ?? "dir:" + (found.hit.cwd ?? "")
        }
        return bySpace.map { key, found in
            let sessions = Dictionary(grouping: found, by: \.hit.sessionPath).map { path, hits in
                SessionGroup(
                    sessionPath: path,
                    title: hits.first?.hit.sessionTitle,
                    hits: hits.sorted { newestFirst($0.date, $1.date) }
                )
            }
            .sorted { newestFirst($0.newest, $1.newest) }
            let first = found.first?.hit
            return SpaceGroup(
                id: key,
                workspaceID: first?.workspaceId,
                cwd: first?.cwd,
                sessions: sessions
            )
        }
        .sorted { newestFirst($0.sessions.first?.newest, $1.sessions.first?.newest) }
    }
}

/// Forwards what a search finds from the Rust runtime.
final class SearchBridge: ConversationSearchObserver {
    enum Event: Sendable {
        case progress(UInt64, UInt64)
        case hits([ConversationHit])
        case finished(SearchEnd)
    }

    private let handler: @Sendable (Event) -> Void

    init(_ handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    func onProgress(done: UInt64, total: UInt64) {
        handler(.progress(done, total))
    }

    func onHits(hits: [ConversationHit]) {
        handler(.hits(hits))
    }

    func onFinished(end: SearchEnd) {
        handler(.finished(end))
    }
}
#endif

/// A timestamp as Claude Code writes it, with milliseconds, e.g.
/// 2026-10-18T10:12:33.123Z.
func claudeDate(_ stamp: String?) -> Date? {
    guard let stamp else { return nil }
    return (try? Date(stamp, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
        ?? (try? Date(stamp, strategy: .iso8601))
}
