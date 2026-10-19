import Foundation
import Observation

/// A saved prompt sent with one tap from the input bar.
struct QuickReply: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
}

/// Quick replies of this device, persisted as JSON in Application Support.
/// Per device on purpose: what is handy to send differs between iPad and Mac,
/// and the list should not depend on which host is selected.
@MainActor
@Observable
final class QuickReplyStore {
    static let shared = QuickReplyStore()

    /// Shown until the user changes the list; deleting all of them sticks.
    static let defaults = ["weiter", "/compact", "Bitte committen", "Commit und PR erstellen"]

    var replies: [QuickReply] {
        didSet { save() }
    }
    var saveError: String?

    /// Replies worth a button: blank entries from the editor are skipped.
    var usable: [QuickReply] {
        replies.filter { !$0.trimmed.isEmpty }
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/quick-replies.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([QuickReply].self, from: data) {
            replies = stored
        } else {
            replies = Self.defaults.map { QuickReply(text: $0) }
        }
    }

    func add() -> QuickReply {
        let reply = QuickReply(text: "")
        replies.append(reply)
        return reply
    }

    func resetToDefaults() {
        replies = Self.defaults.map { QuickReply(text: $0) }
    }

    /// Drops entries left empty in the editor.
    func removeBlank() {
        let kept = replies.filter { !$0.trimmed.isEmpty }
        if kept.count != replies.count { replies = kept }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(replies).write(to: fileURL, options: .atomic)
            saveError = nil
            #if os(iOS)
            WatchBridge.shared.publishQuickReplies()
            #endif
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension QuickReply {
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
