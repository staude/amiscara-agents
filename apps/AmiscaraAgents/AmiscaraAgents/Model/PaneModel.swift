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
    @ObservationIgnored private(set) var paneID: String?
    /// `HostConnection.generation` the follower belongs to.
    @ObservationIgnored private var generation: Int?
    /// Counts `show` calls; see `stop(_:)`.
    @ObservationIgnored private var showing = 0
    @ObservationIgnored private var live = true

    /// Each load asks for the next step; herdr returns at most
    /// `maxHistoryLines()` rows, and every step is polled again while the
    /// pane changes, so the steps stay coarse.
    private static let historySteps: [UInt32] = [200, 500, maxHistoryLines()]

    /// Whether a requested history step has not arrived yet.
    var isLoadingHistory: Bool {
        historyLines > (content?.historyLines ?? 0)
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
    /// Returns a token for `stop(_:)`.
    @discardableResult
    func show(paneID: String?, on connection: HostConnection?, live: Bool = true) -> Int {
        showing += 1
        follow(paneID: paneID, on: connection, live: live)
        return showing
    }

    private func follow(paneID: String?, on connection: HostConnection?, live: Bool) {
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
        self.paneID = paneID
        generation = connection?.generation
        guard let paneID, let connection else { return }
        let bridge = PaneBridge(
            content: { [weak self] content in
                Task { @MainActor in
                    guard self?.paneID == content.paneId else { return }
                    self?.content = content
                    self?.error = nil
                }
            },
            error: { [weak self] message in
                Task { @MainActor in self?.error = message }
            }
        )
        follow = connection.followPane(paneID, live: live, observer: bridge)
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

    /// Stops following, unless the view was shown again since `token`: on
    /// the iPhone, SwiftUI can end an earlier appearance of the pane view
    /// after the next one began, which stopped the pane just opened (#107).
    func stop(_ token: Int) {
        guard token == showing else { return }
        show(paneID: nil, on: nil)
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

/// Returns once the current task is cancelled, e.g. when the view that
/// started it with `.task` goes away.
func untilCancelled() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3600))
    }
}
