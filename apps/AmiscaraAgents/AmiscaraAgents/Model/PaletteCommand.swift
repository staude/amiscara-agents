import Foundation

// Commands in the quick switcher (#346). Only Foundation here: the tvOS
// target takes this file too, and scripts/command-palette-test.sh builds it
// on its own.

/// A keyboard shortcut as data, so the menus and the switcher's rows show
/// the same keys. The SwiftUI side (`KeyboardShortcut`) is in AppCommands.
struct CommandShortcut: Equatable, Sendable {
    enum Modifier: CaseIterable, Sendable {
        // In the order macOS shows them: ⌃⌥⇧⌘.
        case control, option, shift, command

        var glyph: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// A character such as "k" or "]", or `return`, `up`, `down`, `left`,
    /// `right`.
    let key: String
    let modifiers: Set<Modifier>

    init(_ key: String, _ modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⇧⌘]", "⌃C", "⌥⌘↑".
    var display: String {
        let glyphs = Modifier.allCases.filter(modifiers.contains).map(\.glyph).joined()
        let key = switch key {
        case "return": "↩"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        default: key.uppercased()
        }
        return glyphs + key
    }
}

/// Every shortcut the app has, in one place for the menus and the switcher.
enum Shortcuts {
    static let find = CommandShortcut("f", [.command])
    static let findNext = CommandShortcut("g", [.command])
    static let findPrevious = CommandShortcut("g", [.command, .shift])
    static let switcher = CommandShortcut("k", [.command])
    static let handoff = CommandShortcut("v", [.command, .option])
    static let previousTab = CommandShortcut("[", [.command, .shift])
    static let nextTab = CommandShortcut("]", [.command, .shift])
    static let escape = CommandShortcut(".", [.command])
    static let controlC = CommandShortcut("c", [.control])
    static let enter = CommandShortcut("return", [.command, .shift])
    static let arrowUp = CommandShortcut("up", [.command, .option])
    static let arrowDown = CommandShortcut("down", [.command, .option])
    static let arrowLeft = CommandShortcut("left", [.command, .option])
    static let arrowRight = CommandShortcut("right", [.command, .option])
    static let zoomIn = CommandShortcut("+", [.command])
    static let zoomOut = CommandShortcut("-", [.command])
    static let zoomReset = CommandShortcut("0", [.command])
    static let settings = CommandShortcut(",", [.command])

    /// ⌘1 to ⌘9.
    static func space(_ number: Int) -> CommandShortcut {
        CommandShortcut("\(number)", [.command])
    }

    /// ⌥⌘1 to ⌥⌘3 at a dialog.
    static func option(_ number: Int) -> CommandShortcut {
        CommandShortcut("\(number)", [.command, .option])
    }
}

/// Something the switcher can run: what the menus, the tab bar and the pane
/// header offer for the focused space and pane.
struct PaletteCommand: Identifiable {
    enum Section: Int, Sendable {
        case app, host, space, pane

        var name: String {
            switch self {
            case .app: String(localized: "App")
            case .host: String(localized: "Host")
            case .space: String(localized: "Space")
            case .pane: String(localized: "Pane")
            }
        }
    }

    let id: String
    let title: String
    let section: Section
    var shortcut: CommandShortcut?
    /// Further words a query may match, e.g. "close" next to "schließen".
    var keywords: [String] = []
    let run: @MainActor () -> Void

    /// Title, keywords, then the section's name.
    var fields: [String] {
        [title] + keywords + [section.name]
    }

    /// The same command, run only while `allowed` says so (the app lock).
    func guarded(by allowed: @escaping @MainActor () -> Bool) -> PaletteCommand {
        let run = run
        return PaletteCommand(id: id, title: title, section: section, shortcut: shortcut, keywords: keywords) {
            if allowed() { run() }
        }
    }
}

/// What was typed into the switcher: `>` at the start asks for commands only.
struct PaletteQuery: Equatable {
    let text: String
    let commandsOnly: Bool

    static func parse(_ raw: String) -> PaletteQuery {
        let trimmed = raw.drop(while: \.isWhitespace)
        guard trimmed.first == ">" else { return PaletteQuery(text: String(trimmed), commandsOnly: false) }
        return PaletteQuery(text: String(trimmed.dropFirst()), commandsOnly: true)
    }

    var isEmpty: Bool { SwitcherMatch.words(text).isEmpty }
}

/// A row of the switcher: a space or agent, or a command.
enum PaletteResult<Entry, Command> {
    case entry(Entry)
    case command(Command)
}

enum PaletteResults {
    /// `>` lists the matching commands, all of them without a word. Without
    /// `>` an empty query shows the entries only, as before commands came;
    /// with words both are ranked together, an entry before a command of
    /// the same score, then in their given order.
    static func combine<Entry, Command>(
        entries: [Entry],
        entryFields: (Entry) -> [String],
        commands: [Command],
        commandFields: (Command) -> [String],
        query: PaletteQuery
    ) -> [PaletteResult<Entry, Command>] {
        let words = SwitcherMatch.words(query.text)
        if query.commandsOnly {
            return SwitcherMatch.ranked(commands, fields: commandFields, words: words).map { .command($0.item) }
        }
        guard !words.isEmpty else { return entries.map { .entry($0) } }
        let rankedEntries = SwitcherMatch.ranked(entries, fields: entryFields, words: words)
            .map { (score: $0.score, kind: 0, index: $0.index, result: PaletteResult<Entry, Command>.entry($0.item)) }
        let rankedCommands = SwitcherMatch.ranked(commands, fields: commandFields, words: words)
            .map { (score: $0.score, kind: 1, index: $0.index, result: PaletteResult<Entry, Command>.command($0.item)) }
        return (rankedEntries + rankedCommands)
            .sorted { ($0.score, -$0.kind, -$0.index) > ($1.score, -$1.kind, -$1.index) }
            .map(\.result)
    }
}

/// Matching for the switcher: every word of the query must appear in one of
/// the item's texts, as a substring or, failing that, as letters in order
/// ("hrc" finds "herdr-remote-core"). Word starts rank above substrings,
/// substrings above scattered letters, the first field above the others.
enum SwitcherMatch {
    static func filter<T>(_ items: [T], fields: (T) -> [String], query: String) -> [T] {
        let words = words(query)
        guard !words.isEmpty else { return items }
        return ranked(items, fields: fields, words: words).map(\.item)
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The matching items, best first, with their score and place in
    /// `items`; all of them in order without words.
    static func ranked<T>(_ items: [T], fields: (T) -> [String], words: [String]) -> [(score: Int, index: Int, item: T)] {
        guard !words.isEmpty else {
            return items.enumerated().map { (score: 0, index: $0.offset, item: $0.element) }
        }
        return items.enumerated()
            .compactMap { index, item in
                score(fields(item), words).map { (score: $0, index: index, item: item) }
            }
            .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
    }

    /// `nil` when a word matches nowhere.
    static func score(_ fields: [String], _ words: [String]) -> Int? {
        let fields = fields.map { $0.lowercased() }
        var total = 0
        for word in words {
            var best: Int?
            for (position, field) in fields.enumerated() {
                // The first field (name) weighs a little more.
                let bonus = position == 0 ? 1 : 0
                let points: Int? = if let range = field.range(of: word) {
                    (startsWord(field, at: range.lowerBound) ? 6 : 4) + bonus
                } else if isSubsequence(word, of: field) {
                    1
                } else {
                    nil
                }
                if let points, points > (best ?? 0) { best = points }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    private static func startsWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !before.isLetter && !before.isNumber
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = word[...]
        for char in text where char == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}
