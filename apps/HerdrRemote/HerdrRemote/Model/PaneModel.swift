import Foundation
import Observation

/// The live screen of the pane shown in the detail view.
@MainActor
@Observable
final class PaneModel {
    private(set) var content: PaneContent?
    private(set) var error: String?
    @ObservationIgnored private var follow: PaneFollow?
    @ObservationIgnored private(set) var paneID: String?

    func show(paneID: String?, on connection: HostConnection?) {
        guard paneID != self.paneID else { return }
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
