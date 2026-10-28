import Foundation
import Observation

/// The live screen of the pane shown in the detail view, or of one pane of
/// a split tab, optionally with scrollback above it. Only a live pane (the
/// selected one) loads history; a background pane stays screen-only.
@MainActor
@Observable
final class PaneModel {
    /// What the pane view shows: the agent's transcript when one was
    /// loaded, else the live screen.
    var content: PaneContent? { agentHistory ?? followed }
    /// The followed screen, with scrollback when asked for.
    private var followed: PaneContent?
    /// When the shown screen last changed, also for a screen kept from
    /// before (#276).
    private(set) var updatedAt: Date?
    private(set) var error: String?
    /// The transcript of a full-screen agent such as Claude Code, which
    /// herdr keeps no scrollback for (#187): read once on request and shown
    /// instead of the live screen until `hideHistory()`. Plain text.
    private(set) var agentHistory: PaneContent?
    private(set) var isLoadingAgentHistory = false
    /// Why the last step through a full-screen agent failed.
    private(set) var agentError: String?
    /// The app scrolled the agent's own view up, which also moves it on
    /// the host; it goes back down when the pane is left.
    @ObservationIgnored private var agentScrolled = false
    @ObservationIgnored private weak var connection: HostConnection?
    /// History rows asked for; 0 shows only the visible screen.
    private(set) var historyLines: UInt32 = 0
    @ObservationIgnored private var follow: PaneFollow?
    /// Rows of the last screen-only read, to tell whether history brought
    /// anything above it.
    @ObservationIgnored private var screenRows = 0
    @ObservationIgnored private(set) var paneID: String?
    /// `HostConnection.generation` the follower belongs to.
    @ObservationIgnored private var generation: Int?
    @ObservationIgnored private var isLive = true
    /// Lines the terminal wrapped come joined, see `setUnwrap`.
    @ObservationIgnored private var unwrap = false

    /// Setting: offer the steps through full-screen agents. Off by default,
    /// since they move the agent's view on the host too.
    static let fullscreenScrollKey = "scrollFullscreenAgents"
    /// The setting "Zeilen umbrechen" (#191).
    static let wrapLinesKey = "terminalWrapLines"

    /// Each load asks for the next step; herdr returns at most
    /// `maxHistoryLines()` rows, and every step is polled again while the
    /// pane changes, so the steps stay coarse.
    private static let historySteps: [UInt32] = [200, 500, maxHistoryLines()]

    /// Whether a requested history step has not arrived yet.
    var isLoadingHistory: Bool {
        historyLines > (followed?.historyLines ?? 0)
    }

    /// History was read, but herdr has nothing above the screen: full-screen
    /// programs such as Claude Code redraw in place, nothing scrolls off.
    var hasNoHistory: Bool {
        guard let content = followed, agentHistory == nil, !isLoadingHistory, content.historyLines > 0, !content.truncated else { return false }
        return screenRows > 0 && content.lines.count <= screenRows
    }

    /// Whether another load can bring older rows.
    var canLoadMoreHistory: Bool {
        // A kept screen while the host is not live (#276): nobody to ask.
        guard let content = followed, connection?.isLive == true, agentHistory == nil, !isLoadingHistory else { return false }
        return content.historyLines == 0
            || (content.truncated && content.historyLines < maxHistoryLines())
    }

    func loadMoreHistory() {
        guard isLive, canLoadMoreHistory else { return }
        let next = Self.historySteps.first { $0 > historyLines } ?? maxHistoryLines()
        historyLines = next
        follow?.setHistoryLines(lines: next)
    }

    func hideHistory() {
        historyLines = 0
        agentHistory = nil
        agentError = nil
        follow?.setHistoryLines(lines: 0)
    }

    /// Reads the transcript of the full-screen agent in the pane. herdr
    /// scrolls the agent on the host through it and back down, which takes
    /// a moment and works only while the agent is idle.
    func loadAgentHistory() {
        guard let paneID, let connection, !isLoadingAgentHistory else { return }
        isLoadingAgentHistory = true
        agentError = nil
        Task {
            defer { if paneID == self.paneID { isLoadingAgentHistory = false } }
            do {
                let history = try await connection.agentHistory(paneID: paneID)
                if paneID == self.paneID { agentHistory = history }
            } catch {
                if paneID == self.paneID { agentError = inputErrorMessage(error) }
            }
        }
    }

    /// Scrolls the full-screen agent's own view; the live screen follows.
    func scrollAgent(_ step: ScrollStep) {
        guard let paneID, let connection else { return }
        agentScrolled = step != .bottom
        agentError = nil
        Task {
            do {
                try await connection.scrollAgent(step, in: paneID)
            } catch {
                if paneID == self.paneID { agentError = inputErrorMessage(error) }
            }
        }
    }

    /// `live: false` reads the pane only every few seconds; for a pane shown
    /// beside the selected one, since every read costs a round trip.
    ///
    /// The follower lives as long as this model: views call this when their
    /// pane or session changes, never stop it on disappearing. On the iPhone
    /// a collapsed split view shows a pane view again without a new appear
    /// after it disappeared, so a pane stopped there kept loading (#107).
    /// Releasing the model releases the follower, which stops it.
    func show(paneID: String?, on connection: HostConnection?, live: Bool = true) {
        guard paneID != self.paneID || connection?.generation != generation else {
            setLive(live)
            return
        }
        if agentScrolled, let paneID = self.paneID, let previous = self.connection {
            Task { try? await previous.scrollAgent(.bottom, in: paneID) }
        }
        isLive = live
        follow?.stop()
        follow = nil
        // The last screen kept, until the pane reads a new one (#276).
        let kept = paneID.flatMap { paneID in connection.flatMap { PaneCache.shared.entry(host: $0.id, pane: paneID) } }
        followed = kept?.content
        updatedAt = kept?.date
        error = nil
        historyLines = 0
        screenRows = 0
        agentHistory = nil
        isLoadingAgentHistory = false
        agentError = nil
        agentScrolled = false
        self.paneID = paneID
        self.connection = connection
        generation = connection?.generation
        guard let paneID, let connection else { return }
        let hostID = connection.id
        let bridge = PaneBridge(
            content: { [weak self] content in
                Task { @MainActor in
                    guard let self, self.paneID == content.paneId else { return }
                    if content.historyLines == 0 { self.screenRows = content.lines.count }
                    self.followed = content
                    self.updatedAt = .now
                    self.error = nil
                    PaneCache.shared.record(content, host: hostID, pane: content.paneId)
                }
            },
            error: { [weak self] message in
                // A closed tab or pane: the view moves on to another tab as
                // soon as the session reports it; until then this is no
                // error worth flashing (herdr logs it as pane_not_found).
                guard !message.contains("pane_not_found") else { return }
                Task { @MainActor in self?.error = message }
            }
        )
        follow = connection.followPane(paneID, live: live, observer: bridge)
        if unwrap { follow?.setUnwrap(unwrap: true) }
    }

    /// Joins the rows the terminal wrapped at the pane width, for a view
    /// that wraps lines at its own width (#191). Drops loaded history, whose
    /// row count would no longer match the screen's.
    func setUnwrap(_ unwrap: Bool) {
        guard unwrap != self.unwrap else { return }
        self.unwrap = unwrap
        if historyLines > 0 { hideHistory() }
        follow?.setUnwrap(unwrap: unwrap)
    }

    /// Switches the pace without restarting; the pane is read once right away.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        follow?.setLive(live: live)
        // A pane beside the selected one shows only its screen: a history
        // read there would cost the most for the pane looked at least.
        if !live, historyLines > 0 { hideHistory() }
    }
}

final class PaneBridge: PaneObserver {
    private let content: @Sendable (PaneContent) -> Void
    private let error: @Sendable (String) -> Void

    init(
        content: @escaping @Sendable (PaneContent) -> Void,
        error: @escaping @Sendable (String) -> Void
    ) {
        self.content = content
        self.error = error
    }

    func onContent(content: PaneContent) {
        self.content(content)
    }

    func onError(message: String) {
        error(message)
    }
}
