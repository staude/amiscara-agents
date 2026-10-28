import Foundation

/// The rows of a pane's screen that carry what an agent said (#275). At the
/// bottom of a Claude Code screen are nearly always the input box and the
/// footer, which say nothing about what it does.
enum ScreenLines {
    /// Hints in the footer of agent TUIs such as Claude Code.
    static let footer = ["for shortcuts", "esc to", "accept edits", "bypass permissions", "plan mode", "⏵", "ctrl+"]

    /// A trimmed row that is empty, only frame or prompt, or the footer.
    static func isChrome(_ row: String) -> Bool {
        row.isEmpty
            || row.allSatisfy { "─│╭╮╰╯>❯ ".contains($0) }
            || footer.contains { row.localizedCaseInsensitiveContains($0) }
    }

    /// The last `count` rows with content, top to bottom, without the frame
    /// around them and Claude Code's ⏺ marker.
    static func last(_ count: Int, of screen: String) -> [String] {
        let rows = screen.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isChrome($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│⏺").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        return Array(rows.suffix(count))
    }
}
