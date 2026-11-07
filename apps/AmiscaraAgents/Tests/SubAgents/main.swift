// Checks how sub-agents nest under their parent (#330) without the UI:
// child, grandchild, missing parent, kept in place, cycle. Built by
// scripts/sub-agents-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

struct Agent {
    let id: String
    let parent: String?
    var pinned = false
}

@MainActor func nested(_ agents: [Agent]) -> [String] {
    SubAgentTree.nest(agents, id: \.id, parent: \.parent, keepInPlace: \.pinned)
        .map { "\($0.item.id):\($0.depth)" }
}

@MainActor func run() {
    check(nested([]) == [], "nothing stays nothing")

    let family = [
        Agent(id: "a", parent: nil),
        Agent(id: "b", parent: nil),
        Agent(id: "a1", parent: "a"),
        Agent(id: "a1x", parent: "a1"),
        Agent(id: "a2", parent: "a"),
    ]
    check(nested(family) == ["a:0", "a1:1", "a1x:2", "a2:1", "b:0"],
          "children follow their parent, grandchildren theirs, siblings in order: \(nested(family))")

    let early = [Agent(id: "c", parent: "p"), Agent(id: "p", parent: nil)]
    check(nested(early) == ["p:0", "c:1"], "a child listed before its parent moves behind it")

    let orphan = [Agent(id: "a", parent: nil), Agent(id: "o", parent: "gone")]
    check(nested(orphan) == ["a:0", "o:0"], "a missing parent leaves the child in place")

    let pinned = [
        Agent(id: "p", parent: "a", pinned: true),
        Agent(id: "a", parent: nil),
        Agent(id: "c", parent: "a"),
    ]
    check(nested(pinned) == ["p:0", "a:0", "c:1"], "a pinned sub-agent keeps its place")

    let cycle = [
        Agent(id: "x", parent: "y"),
        Agent(id: "y", parent: "x"),
        Agent(id: "z", parent: "x"),
        Agent(id: "s", parent: "s"),
    ]
    check(nested(cycle) == ["x:0", "z:1", "y:0", "s:0"], "a cycle stays in place: \(nested(cycle))")

    let deep = (0..<6).map { Agent(id: "d\($0)", parent: $0 == 0 ? nil : "d\($0 - 1)") }
    check(nested(deep) == ["d0:0", "d1:1", "d2:2", "d3:3", "d4:3", "d5:3"], "indentation stops at three")

    let twice = [Agent(id: "a", parent: nil), Agent(id: "a", parent: nil), Agent(id: "c", parent: "a")]
    check(nested(twice) == ["a:0", "c:1", "a:0"], "a duplicate id does not crash")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("sub-agents: ok")
