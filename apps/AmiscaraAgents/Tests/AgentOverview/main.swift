// Checks the overview of all hosts (#274) without the UI: groups, the
// Mac's boards for hosts without a connection, sorting. Built by
// scripts/agent-overview-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

let now = Date(timeIntervalSince1970: 1_000_000)
func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

func agent(_ pane: String, _ state: WidgetSnapshot.State, since: Date? = nil) -> WidgetSnapshot.Agent {
    WidgetSnapshot.Agent(paneID: pane, workspaceID: "w-\(pane)", place: "Space · Tab", name: "claude", state: state, since: since)
}

func host(_ name: String, live: Bool, liveAt: Date? = nil, key: String? = nil, _ agents: [WidgetSnapshot.Agent]) -> AgentOverview.Host {
    AgentOverview.Host(id: UUID(), name: name, live: live, liveAt: liveAt ?? (live ? now : nil), hostKey: key, agents: agents)
}

func board(_ key: String, updated: Date, _ agents: [WidgetSnapshot.Agent]) -> CloudBoard {
    CloudBoard(hostKey: key, hostName: "mac", live: true, updated: updated, agents: agents)
}

func panes(_ overview: AgentOverview, _ group: AgentOverview.Group) -> [String] {
    overview.sections.first { $0.group == group }?.rows.map(\.agent.paneID) ?? []
}

// Two connected hosts in three groups (done 1).
do {
    let a = host("a", live: true, [agent("a1", .working, since: ago(3)), agent("a2", .blocked, since: ago(1))])
    let b = host("b", live: true, [agent("b1", .done, since: ago(2)), agent("b2", .blocked, since: ago(5))])
    let overview = AgentOverview(hosts: [a, b], boards: [])
    check(overview.sections.map(\.group) == [.waiting, .working, .done], "three groups in order")
    check(panes(overview, .waiting) == ["a2", "b2"], "waiting from both hosts, newest first")
    check(panes(overview, .working) == ["a1"], "working")
    check(panes(overview, .done) == ["b1"], "done")
    check(overview.waitingCount == 2, "waiting count")
    check(overview.sections.flatMap(\.rows).allSatisfy { $0.staleAt == nil }, "live hosts are not stale")
    check(overview.sections[0].rows[1].hostName == "b", "rows carry their host")
}

// A host without a connection shows the Mac's board, marked (done 2).
do {
    let offline = host("mac", live: false, key: "K", [])
    let overview = AgentOverview(hosts: [offline], boards: [board("K", updated: ago(4), [agent("m1", .blocked)])])
    check(panes(overview, .waiting) == ["m1"], "agents from the board")
    check(overview.sections.first?.rows.first?.staleAt == ago(4), "stale with the board's age")
}

// Its own last state wins when it is newer than the board.
do {
    let offline = host("mac", live: false, liveAt: ago(2), key: "K", [agent("own", .working)])
    let overview = AgentOverview(hosts: [offline], boards: [board("K", updated: ago(10), [agent("old", .blocked)])])
    check(panes(overview, .working) == ["own"] && panes(overview, .waiting).isEmpty, "own state newer than board")
    check(overview.sections.first?.rows.first?.staleAt == ago(2), "stale with its own age")
    let newer = AgentOverview(hosts: [offline], boards: [board("K", updated: ago(1), [agent("new", .blocked)])])
    check(panes(newer, .waiting) == ["new"], "a newer board wins")
}

// Hosts without agents and agents that are ready or unknown stay out.
do {
    let empty = host("empty", live: true, [])
    let idle = host("idle", live: true, [agent("i1", .idle), agent("u1", .unknown)])
    let overview = AgentOverview(hosts: [empty, idle], boards: [])
    check(overview.isEmpty, "nothing to show")
}

// Unknown times last, else host order.
do {
    let a = host("a", live: true, [agent("a1", .blocked), agent("a2", .blocked, since: ago(9))])
    let b = host("b", live: true, [agent("b1", .blocked), agent("b2", .blocked, since: ago(1))])
    let overview = AgentOverview(hosts: [a, b], boards: [])
    check(panes(overview, .waiting) == ["b2", "a2", "a1", "b1"], "sorted by time, unknown last in host order")
}

// A live agent without a time takes it from the board of the same pane and state.
do {
    let live = host("mac", live: true, key: "K", [agent("p1", .blocked), agent("p2", .working)])
    let boards = [board("K", updated: ago(1), [agent("p1", .blocked, since: ago(7)), agent("p2", .done, since: ago(3))])]
    let rows = AgentOverview(hosts: [live], boards: boards).sections.flatMap(\.rows)
    check(rows.first { $0.agent.paneID == "p1" }?.since == ago(7), "time from the board")
    check(rows.first { $0.agent.paneID == "p2" }?.since == nil, "no time from another state")
}

// Snapshots and boards of older builds have no time.
do {
    let json = #"{"paneID":"p","workspaceID":"w","place":"x","name":"n","state":"done"}"#
    let decoded = try? JSONDecoder().decode(WidgetSnapshot.Agent.self, from: Data(json.utf8))
    check(decoded != nil && decoded?.since == nil, "old JSON decodes without a time")
}

if failures > 0 { exit(1) }
print("agent-overview: ok")
