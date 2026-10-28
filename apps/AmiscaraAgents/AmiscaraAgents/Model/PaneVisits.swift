import CryptoKit
import Foundation

/// When each pane was last shown and how its screen ended then (#273), so a
/// pane opened again after a while can offer a summary of what is new. herdr
/// reports no line offset, so the new part is found by locating the last
/// lines seen in the recent scrollback. Only hashes of those lines are kept,
/// no terminal text. Kept on this device for a week, also across launches;
/// the demo mode keeps it in memory.
@MainActor
final class PaneVisits {
    static let shared = PaneVisits()

    struct Entry: Codable, Equatable {
        var seen: Date
        /// SHA-256 of the last lines with text, see `tail(of:)`.
        var tail: [String]
    }

    /// Lines with text that anchor the new output.
    nonisolated static let tailLines = 20
    /// Entries older than this are dropped on loading.
    nonisolated static let keep: TimeInterval = 7 * 24 * 60 * 60

    /// "<host UUID>/<pane id>" to the last visit.
    private var entries: [String: Entry]

    private let fileURL: URL?

    init(fileURL: URL? = nil, now: Date = .now) {
        let url = fileURL ?? (DemoMode.isOn ? nil : FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/pane-visits.json"))
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter { now.timeIntervalSince($0.value.seen) < Self.keep }
        } else {
            entries = [:]
        }
    }

    private static func key(host: UUID, pane: String) -> String { "\(host.uuidString)/\(pane)" }

    func entry(host: UUID, pane: String) -> Entry? {
        entries[Self.key(host: host, pane: pane)]
    }

    func record(host: UUID, pane: String, tail: [String], seen: Date = .now) {
        entries[Self.key(host: host, pane: pane)] = Entry(seen: seen, tail: tail)
        save()
    }

    /// Drops the memory of a removed host.
    func forget(host: UUID) {
        let prefix = host.uuidString + "/"
        let before = entries.count
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        if entries.count != before { save() }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A lost entry only means no summary is offered for that pane.
        }
    }

    /// Hashes of the last up to `tailLines` lines with text, trimmed on both
    /// sides, oldest first.
    nonisolated static func tail(of text: String) -> [String] {
        textLines(text).suffix(tailLines).map { hash($0.text) }
    }

    /// The lines after the last place where `tail` matches consecutive lines
    /// with text; all lines when `tail` is empty or matches nowhere. The
    /// bottom line of `tail` is left out when there are others: often a
    /// prompt or status line that changed in place since.
    nonisolated static func newLines(in text: String, after tail: [String]) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let candidates = textLines(text)
        let tail = tail.count > 1 ? Array(tail.dropLast()) : tail
        guard !tail.isEmpty, candidates.count >= tail.count else { return lines }
        let hashes = candidates.map { hash($0.text) }
        for start in stride(from: hashes.count - tail.count, through: 0, by: -1)
        where Array(hashes[start ..< start + tail.count]) == tail {
            let anchor = candidates[start + tail.count - 1].index
            return Array(lines[(anchor + 1)...])
        }
        return lines
    }

    /// What is new in `text` since a visit that ended with `tail`: the lines
    /// after the anchor, or none when that is only the old bottom line,
    /// a prompt or status line that changed in place.
    nonisolated static func newOutput(in text: String, after tail: [String]) -> [String] {
        let lines = newLines(in: text, after: tail)
        return lines.count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) > 1 ? lines : []
    }

    /// Lines with text, trimmed, with their index in `text`.
    private nonisolated static func textLines(_ text: String) -> [(index: Int, text: String)] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (index, trimmed)
        }
    }

    private nonisolated static func hash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
