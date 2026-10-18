import Foundation
import Observation

/// One occurrence of the search text, as character offsets into the plain
/// text of a line (its spans joined). Character offsets, not string indices,
/// because the same positions are applied to the line's AttributedString.
struct SearchMatch: Hashable, Sendable {
    let line: Int
    let start: Int
    let length: Int
}

/// Find in the lines a pane view shows, including any loaded history.
/// Case and accents are ignored, like Find in most Mac apps.
enum PaneSearch {
    static func matches(of query: String, in lines: [StyledLine]) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var result: [SearchMatch] = []
        for (index, line) in lines.enumerated() {
            let text = line.spans.map(\.text).joined()
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(
                      of: query,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<text.endIndex
                  ) {
                let start = text.distance(from: text.startIndex, to: found.lowerBound)
                let length = text.distance(from: found.lowerBound, to: found.upperBound)
                result.append(SearchMatch(line: index, start: start, length: length))
                // An empty range cannot happen for a non-empty query, but
                // never loop on one.
                searchStart = found.upperBound > found.lowerBound
                    ? found.upperBound
                    : text.index(after: found.lowerBound)
            }
        }
        return result
    }
}

/// What the terminal view needs to show a search: all matches by line, the
/// current one, and a counter that asks it to scroll there.
struct SearchHighlight: Equatable {
    var byLine: [Int: [SearchMatch]] = [:]
    var current: SearchMatch?
    /// Bumped when the user moves to another match; the view scrolls only
    /// then, so live output does not keep pulling the view to the match.
    var scrollRequest = 0
}

/// Search state of one pane view: the full-width pane or the selected tile
/// of a split tab. Matches are computed from the content on every render,
/// so live output and newly loaded history are searched as they arrive.
@MainActor
@Observable
final class PaneSearchState {
    var isOpen = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            matchIndex = nil
            scrollRequest += 1
        }
    }
    /// Index into the current matches; `nil` means the last one, nearest
    /// to the bottom where the view starts.
    var matchIndex: Int?
    private(set) var scrollRequest = 0
    /// Bumped by ⌘F, also while the bar is open, to focus its field.
    private(set) var focusRequest = 0

    func open() {
        isOpen = true
        focusRequest += 1
    }

    func close() {
        isOpen = false
        query = ""
        matchIndex = nil
    }

    func matches(in content: PaneContent?) -> [SearchMatch] {
        guard isOpen else { return [] }
        return PaneSearch.matches(of: query, in: content?.lines ?? [])
    }

    /// The current match's position, kept in range while live output
    /// changes the number of matches.
    func currentIndex(_ matches: [SearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return min(matchIndex ?? matches.count - 1, matches.count - 1)
    }

    func step(_ delta: Int, in matches: [SearchMatch]) {
        guard let index = currentIndex(matches) else { return }
        matchIndex = (index + delta + matches.count) % matches.count
        scrollRequest += 1
    }

    func highlight(_ matches: [SearchMatch]) -> SearchHighlight {
        SearchHighlight(
            byLine: Dictionary(grouping: matches, by: \.line),
            current: currentIndex(matches).map { matches[$0] },
            scrollRequest: scrollRequest
        )
    }

    /// What the Find commands (⌘F, ⌘G, ⇧⌘G) act on.
    func actions(_ matches: [SearchMatch]) -> PaneSearchActions {
        PaneSearchActions(
            open: { [weak self] in self?.open() },
            step: { [weak self] delta in self?.step(delta, in: matches) },
            canStep: isOpen && !matches.isEmpty
        )
    }
}
