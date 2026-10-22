import Foundation
import Observation

/// The live screen of the pane shown in the detail view, or of one pane of
/// a split tab, optionally with scrollback above it. Only a live pane (the
/// selected one) loads history; a background pane stays screen-only.
@MainActor
@Observable
final class PaneModel {
    private(set) var content: PaneContent?
    private(set) var error: String?
    /// History rows asked for; 0 shows only the visible screen.
    private(set) var historyLines: UInt32 = 0
    @ObservationIgnored private var follow: PaneFollow?
    /// Rows of the last screen-only read, to tell whether history brought
    /// anything above it.
    @ObservationIgnored private var screenRows = 0
    @ObservationIgnored private(set) var paneID: String?
    /// `HostConnection.generation` the follower belongs to.
    @ObservationIgnored private var generation: Int?
    @ObservationIgnored private var live = true
    /// Lines the terminal wrapped come joined, see `setUnwrap`.
    @ObservationIgnored private var unwrap = false

    /// The setting "Zeilen umbrechen" (#191).
    static let wrapLinesKey = "terminalWrapLines"

    /// Each load asks for the next step; herdr returns at most
    /// `maxHistoryLines()` rows, and every step is polled again while the
    /// pane changes, so the steps stay coarse.
    private static let historySteps: [UInt32] = [200, 500, maxHistoryLines()]

    /// Whether a requested history step has not arrived yet.
    var isLoadingHistory: Bool {
        historyLines > (content?.historyLines ?? 0)
    }

    /// History was read, but herdr has nothing above the screen: full-screen
    /// programs such as Claude Code redraw in place, nothing scrolls off.
    var hasNoHistory: Bool {
        guard let content, !isLoadingHistory, content.historyLines > 0, !content.truncated else { return false }
        return screenRows > 0 && content.lines.count <= screenRows
    }

    /// Whether another load can bring older rows.
    var canLoadMoreHistory: Bool {
        guard let content, !isLoadingHistory else { return false }
        return content.historyLines == 0
            || (content.truncated && content.historyLines < maxHistoryLines())
    }

    func loadMoreHistory() {
        guard live, canLoadMoreHistory else { return }
        let next = Self.historySteps.first { $0 > historyLines } ?? maxHistoryLines()
        historyLines = next
        follow?.setHistoryLines(lines: next)
    }

    func hideHistory() {
        historyLines = 0
        follow?.setHistoryLines(lines: 0)
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
        self.live = live
        follow?.stop()
        follow = nil
        content = nil
        error = nil
        historyLines = 0
        screenRows = 0
        self.paneID = paneID
        generation = connection?.generation
        guard let paneID, let connection else { return }
        let bridge = PaneBridge(
            content: { [weak self] content in
                Task { @MainActor in
                    guard let self, self.paneID == content.paneId else { return }
                    if content.historyLines == 0 { self.screenRows = content.lines.count }
                    self.content = content
                    self.error = nil
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
        guard live != self.live else { return }
        self.live = live
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
