import Foundation
import Observation

/// The live screen of the pane shown in the detail view, or of one pane of
/// a split tab.
@MainActor
@Observable
final class PaneModel {
    private(set) var content: PaneContent?
    private(set) var error: String?
    @ObservationIgnored private var follow: PaneFollow?
    @ObservationIgnored private(set) var paneID: String?
    @ObservationIgnored private var live = true

    /// `live: false` reads the pane only every few seconds; for a pane shown
    /// beside the selected one, since every read costs a round trip.
    func show(paneID: String?, on connection: HostConnection?, live: Bool = true) {
        guard paneID != self.paneID else {
            setLive(live)
            return
        }
        self.live = live
        follow?.stop()
        follow = nil
        content = nil
        error = nil
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
        follow = connection.followPane(paneID, live: live, observer: bridge)
    }

    /// Switches the pace without restarting; the pane is read once right away.
    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        follow?.setLive(live: live)
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
