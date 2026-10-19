#if os(iOS)
import Foundation
import WatchConnectivity

/// The iPhone's side of the Watch app (#157): hands the Watch the agents as
/// this iPhone sees them and sends the answers chosen there over its own
/// SSH session. A message from the Watch launches the app in the
/// background when it is not running; the store then reconnects first, as
/// for a notification button.
///
/// iPads have no Watch; `WCSession.isSupported()` is false there and this
/// does nothing.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()

    /// Sends `key` to `pane` on `host`; `nil` when it went out, else why
    /// not. Set by the store.
    @MainActor var answer: ((_ host: UUID, _ pane: String, _ key: String) async -> String?)?

    /// The snapshot waiting for an activated session.
    @MainActor private var pending: WidgetSnapshot?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Activates the session; call early at launch, so a message that
    /// launched the app finds a delegate.
    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Hands the Watch the newest snapshot. The application context keeps
    /// only the last one, which is all the Watch needs.
    @MainActor
    func publish(_ snapshot: WidgetSnapshot) {
        guard let session else { return }
        guard session.activationState == .activated else {
            pending = snapshot
            return
        }
        guard session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? session.updateApplicationContext([WatchMessage.snapshotKey: data])
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            if let pending {
                self.pending = nil
                publish(pending)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After switching to another Watch, talk to the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // WatchConnectivity calls the handler once, from any thread.
        nonisolated(unsafe) let reply = replyHandler
        guard let request = WatchMessage.parseAnswer(message) else {
            reply(WatchMessage.reply(error: String(localized: "Unbekannte Anfrage von der Watch.")))
            return
        }
        Task { @MainActor in
            guard let answer else {
                reply(WatchMessage.reply(error: String(localized: "Die App ist nicht bereit.")))
                return
            }
            reply(WatchMessage.reply(error: await answer(request.host, request.pane, request.key)))
        }
    }
}
#endif
