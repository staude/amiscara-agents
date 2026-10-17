import Foundation

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
