import Foundation

/// What iPhone and Watch say to each other over WatchConnectivity (#157).
/// The Watch cannot reach a host (no sockets on watchOS, no NetBird), so
/// it reads the agents from the iPhone and from iCloud and asks the iPhone
/// to send answers. Plain property-list dictionaries, as WatchConnectivity
/// wants them.
enum WatchMessage {
    /// Application context key: the iPhone's `WidgetSnapshot` as JSON. It
    /// names the hosts with their key fingerprints, so the Watch can add
    /// the Mac's boards from iCloud.
    static let snapshotKey = "snapshot"
    /// Application context key: the iPhone's quick replies (#54) as
    /// strings, for prompts from the Watch (#159).
    static let quickRepliesKey = "quickReplies"

    enum Field {
        static let kind = "kind"
        static let host = "host"
        static let pane = "pane"
        static let key = "key"
        static let text = "text"
        static let ok = "ok"
        static let error = "error"
    }

    /// Message kind: send `key` to `pane` on `host`.
    static let answerKind = "answer"
    /// Message kind: send `text` as a prompt to the agent in `pane` (#159).
    static let promptKind = "prompt"

    static func answer(host: UUID, pane: String, key: String) -> [String: Any] {
        [Field.kind: answerKind, Field.host: host.uuidString, Field.pane: pane, Field.key: key]
    }

    static func prompt(host: UUID, pane: String, text: String) -> [String: Any] {
        [Field.kind: promptKind, Field.host: host.uuidString, Field.pane: pane, Field.text: text]
    }

    /// What the Watch asks the iPhone to send.
    enum Request {
        case answer(host: UUID, pane: String, key: String)
        case prompt(host: UUID, pane: String, text: String)
    }

    /// A request the iPhone received.
    static func parseRequest(_ message: [String: Any]) -> Request? {
        guard let host = (message[Field.host] as? String).flatMap(UUID.init(uuidString:)),
              let pane = message[Field.pane] as? String
        else { return nil }
        switch message[Field.kind] as? String {
        case answerKind:
            return (message[Field.key] as? String).map { .answer(host: host, pane: pane, key: $0) }
        case promptKind:
            return (message[Field.text] as? String).map { .prompt(host: host, pane: pane, text: $0) }
        default:
            return nil
        }
    }

    static func reply(error: String?) -> [String: Any] {
        error.map { [Field.ok: false, Field.error: $0] } ?? [Field.ok: true]
    }

    /// `nil` when the iPhone sent the key, else why not.
    static func parseReply(_ reply: [String: Any]) -> String? {
        reply[Field.ok] as? Bool == true
            ? nil
            : reply[Field.error] as? String ?? String(localized: "Das iPhone hat die Antwort nicht gesendet.")
    }
}
