import Foundation
import Observation

/// Prompts and commands sent from the composer, per pane (#229), newest
/// first, so an earlier one can be picked, edited and sent again. Kept on
/// this device only; the demo mode keeps them in memory.
@MainActor
@Observable
final class PromptHistory {
    static let shared = PromptHistory()

    /// Entries kept per pane.
    static let limit = 50
    /// Panes kept; pane ids are not reused, so old ones only take space.
    static let paneLimit = 200

    private struct Stored: Codable {
        /// "<host UUID>/<pane id>" to its prompts, newest first.
        var prompts: [String: [String]] = [:]
        var used: [String: Date] = [:]
    }

    private var stored: Stored

    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (DemoMode.isOn ? nil : FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/prompt-history.json"))
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    static func key(host: UUID, pane: String) -> String { "\(host.uuidString)/\(pane)" }

    func prompts(for key: String) -> [String] { stored.prompts[key] ?? [] }

    /// Puts `prompt` first; an equal older entry moves up instead of
    /// appearing twice.
    func record(_ prompt: String, for key: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        var list = stored.prompts[key] ?? []
        list.removeAll { $0 == prompt }
        list.insert(prompt, at: 0)
        stored.prompts[key] = Array(list.prefix(Self.limit))
        stored.used[key] = .now
        if stored.prompts.count > Self.paneLimit {
            let oldest = stored.prompts.keys.sorted { (stored.used[$0] ?? .distantPast) < (stored.used[$1] ?? .distantPast) }
            for old in oldest.prefix(stored.prompts.count - Self.paneLimit) { forget(old) }
        }
        save()
    }

    func remove(_ prompt: String, for key: String) {
        stored.prompts[key]?.removeAll { $0 == prompt }
        if stored.prompts[key]?.isEmpty == true { forget(key) }
        save()
    }

    func clear(_ key: String) {
        forget(key)
        save()
    }

    private func forget(_ key: String) {
        stored.prompts[key] = nil
        stored.used[key] = nil
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost history entry is not worth an error in the composer.
        }
    }
}
