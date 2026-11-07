import Foundation

/// Sub-agents under their parent agent (#330). herdr-core knows which
/// terminal started which; a sub-agent comes right after its parent and
/// the parent's sub-agents placed before it, one step further in. No FFI
/// types in here, so the tests build it without the core.
enum SubAgentTree {
    /// Deepest indentation; deeper sub-agents stay at this step.
    static let maxDepth = 3

    /// `items` with every element whose parent is in the list placed behind
    /// that parent and its descendants placed so far, siblings in their
    /// input order, at the parent's depth plus one. Elements without a
    /// parent in the list, with `keepInPlace` (e.g. pinned ones) or in a
    /// cycle of parents keep their place at depth 0.
    static func nest<T>(
        _ items: [T],
        id: (T) -> String,
        parent: (T) -> String?,
        keepInPlace: (T) -> Bool = { _ in false }
    ) -> [(item: T, depth: Int)] {
        let ids = items.map(id)
        // The first element wins when the server sends an id twice.
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var up: [Int?] = items.enumerated().map { offset, item in
            guard !keepInPlace(item),
                  let parentID = parent(item),
                  let parentIndex = index[parentID],
                  parentIndex != offset
            else { return nil }
            return parentIndex
        }
        // Every element of a cycle stays in place.
        let inCycle = up.indices.filter { start in
            var seen: Set<Int> = [start]
            var current = up[start]
            while let next = current {
                if next == start { return true }
                if !seen.insert(next).inserted { return false }
                current = up[next]
            }
            return false
        }
        for offset in inCycle {
            up[offset] = nil
        }

        var children: [Int: [Int]] = [:]
        for (offset, parentIndex) in up.enumerated() {
            if let parentIndex {
                children[parentIndex, default: []].append(offset)
            }
        }
        var result: [(item: T, depth: Int)] = []
        result.reserveCapacity(items.count)
        func place(_ offset: Int, depth: Int) {
            result.append((item: items[offset], depth: min(depth, maxDepth)))
            for child in children[offset] ?? [] {
                place(child, depth: depth + 1)
            }
        }
        for offset in up.indices where up[offset] == nil {
            place(offset, depth: 0)
        }
        return result
    }
}
