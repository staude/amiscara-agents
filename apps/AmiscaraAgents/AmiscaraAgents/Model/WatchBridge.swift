#if os(iOS)
import Foundation
import WatchConnectivity

/// The iPhone's side of the Watch app (#157): hands the Watch the agents as
/// this iPhone sees them and the quick replies, and sends the answers and
/// prompts chosen there (#159) over its own SSH session. A message from the Watch launches the app in the
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
    /// Sends `text` as a prompt to the agent in `pane` on `host`; `nil`
    /// when it went out, else why not. Set by the store.
    @MainActor var prompt: ((_ host: UUID, _ pane: String, _ text: String) async -> String?)?

    /// The last snapshot, sent again with changed quick replies.
    @MainActor private var snapshot: Data?
    /// A context waits for an activated session.
    @MainActor private var pending = false

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
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        self.snapshot = data
        sendContext()
    }

    /// Hands the Watch the changed quick replies.
    @MainActor
    func publishQuickReplies() {
        sendContext()
    }

    /// The context replaces the previous one as a whole, so it always
    /// carries both the snapshot and the quick replies.
    @MainActor
    private func sendContext() {
        guard let session else { return }
        guard session.activationState == .activated else {
            pending = true
            return
        }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        var context: [String: Any] = [
            WatchMessage.quickRepliesKey: QuickReplyStore.shared.usable.map(\.trimmed),
        ]
        if let snapshot { context[WatchMessage.snapshotKey] = snapshot }
        try? session.updateApplicationContext(context)
    }

    private static var notReady: String { String(localized: "Die App ist nicht bereit.") }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            if pending {
                pending = false
                sendContext()
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
        guard let request = WatchMessage.parseRequest(message) else {
            reply(WatchMessage.reply(error: String(localized: "Unbekannte Anfrage von der Watch.")))
            return
        }
        Task { @MainActor in
            let error: String?
            switch request {
            case .answer(let host, let pane, let key):
                guard let answer else { return reply(WatchMessage.reply(error: Self.notReady)) }
                error = await answer(host, pane, key)
            case .prompt(let host, let pane, let text):
                guard let prompt else { return reply(WatchMessage.reply(error: Self.notReady)) }
                error = await prompt(host, pane, text)
            }
            reply(WatchMessage.reply(error: error))
        }
    }
}
#endif
