import Foundation
import Observation

/// The live screen of the pane shown in the detail view, optionally with
/// scrollback above it.
@MainActor
@Observable
final class PaneModel {
    private(set) var content: PaneContent?
    private(set) var error: String?
    /// History rows asked for; 0 shows only the visible screen.
    private(set) var historyLines: UInt32 = 0
    @ObservationIgnored private var follow: PaneFollow?
    @ObservationIgnored private(set) var paneID: String?

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
        guard canLoadMoreHistory else { return }
        let next = Self.historySteps.first { $0 > historyLines } ?? maxHistoryLines()
        historyLines = next
        follow?.setHistoryLines(lines: next)
    }

    func hideHistory() {
        historyLines = 0
        follow?.setHistoryLines(lines: 0)
    }

    func show(paneID: String?, on connection: HostConnection?) {
        guard paneID != self.paneID else { return }
        follow?.stop()
        follow = nil
        content = nil
        error = nil
        historyLines = 0
        self.paneID = paneID
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
        follow = connection.followPane(paneID, observer: bridge)
    }

    func stop() {
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
