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

func host(
    _ name: String, live: Bool, liveAt: Date? = nil, key: String? = nil, pinned: Set<String> = [], _ agents: [WidgetSnapshot.Agent]
) -> AgentOverview.Host {
    AgentOverview.Host(id: UUID(), name: name, live: live, liveAt: liveAt ?? (live ? now : nil), hostKey: key, agents: agents, pinned: pinned)
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
    let unconnected = CloudBoard(hostKey: "K", hostName: "mac", live: false, updated: ago(1), agents: [agent("rewritten", .blocked)])
    check(panes(AgentOverview(hosts: [offline], boards: [unconnected]), .working) == ["own"], "a board the Mac wrote without a connection is not newer")
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

// Pinned agents (#334) first in a group of their own, in every state,
// by urgency and then time; not again in their state's group.
do {
    let a = host("a", live: true, pinned: ["a1", "a3", "a4"], [
        agent("a1", .idle), agent("a2", .blocked, since: ago(1)),
        agent("a3", .working, since: ago(2)), agent("a4", .blocked, since: ago(9)),
    ])
    let b = host("b", live: true, pinned: ["b1"], [agent("b1", .blocked, since: ago(3)), agent("b2", .working)])
    let overview = AgentOverview(hosts: [a, b], boards: [])
    check(overview.sections.map(\.group) == [.pinned, .waiting, .working], "pinned group first")
    check(panes(overview, .pinned) == ["b1", "a4", "a3", "a1"], "pinned by urgency, then newest first, ready ones too")
    check(panes(overview, .waiting) == ["a2"], "pinned not again under waiting")
    check(panes(overview, .working) == ["b2"], "pinned not again under working")
    check(overview.sections[0].rows.allSatisfy(\.pinned) && !overview.sections[1].rows.contains(where: \.pinned), "rows carry the pin")
    check(overview.waitingCount == 3, "waiting count includes pinned waiting agents")
    let unpinned = AgentOverview(hosts: [host("a", live: true, [agent("a2", .blocked, since: ago(1)), agent("a1", .idle)])], boards: [])
    check(unpinned.sections.map(\.group) == [.waiting] && panes(unpinned, .waiting) == ["a2"], "without pins as before")
    let other = host("c", live: true, pinned: ["gone"], [agent("c1", .idle)])
    check(AgentOverview(hosts: [other], boards: []).isEmpty, "a pin of a missing pane shows nothing")
}

// Snapshots and boards of older builds have no time.
do {
    let json = #"{"paneID":"p","workspaceID":"w","place":"x","name":"n","state":"done"}"#
    let decoded = try? JSONDecoder().decode(WidgetSnapshot.Agent.self, from: Data(json.utf8))
    check(decoded != nil && decoded?.since == nil, "old JSON decodes without a time")
}

// The rule the host dashboard (#278) shares: newest board per key, and
// only a connected board newer than the last connection stands in.
do {
    let old = board("K", updated: ago(10), [])
    let new = board("K", updated: ago(3), [])
    let other = board("L", updated: ago(1), [])
    check(AgentOverview.newestBoard(for: "K", in: [old, new, other]) == new, "newest board for the key")
    check(AgentOverview.newestBoard(for: nil, in: [old, new]) == nil, "no key, no board")
    check(AgentOverview.newestBoard(for: "X", in: [old, new]) == nil, "unknown key, no board")
    check(AgentOverview.standsIn(old, liveAt: nil), "never connected here: any board")
    check(AgentOverview.standsIn(new, liveAt: ago(5)), "a connected board newer than the last connection")
    check(!AgentOverview.standsIn(old, liveAt: ago(5)), "not an older board, e.g. a Mac's own copy after a reconnect")
    let rewritten = CloudBoard(hostKey: "K", hostName: "mac", live: false, updated: ago(1), agents: [])
    check(!AgentOverview.standsIn(rewritten, liveAt: ago(5)), "not a board a Mac without connection rewrote")
}

// The last connected time: connected, dropped, reconnected (LiveClock).
do {
    var clock = LiveClock()
    clock.update(wasLive: false, isLive: false, now: ago(30))
    check(clock.liveAt == nil, "never connected has no time")
    clock.update(wasLive: false, isLive: true, now: ago(20))
    check(clock.liveAt == ago(20), "an update while live")
    clock.update(wasLive: true, isLive: false, now: ago(10))
    check(clock.liveAt == ago(10), "the update that ends the connection, however quiet the host was")
    clock.update(wasLive: false, isLive: false, now: ago(5))
    check(clock.liveAt == ago(10), "later updates without connection keep it")

    clock.update(wasLive: false, isLive: true, now: ago(4))
    clock.reconnecting(live: true)
    clock.update(wasLive: true, isLive: false, now: ago(1))
    check(clock.liveAt == ago(4), "a reconnect of a link that looked live keeps the last live time")
    clock.update(wasLive: false, isLive: true, now: now)
    clock.update(wasLive: true, isLive: false, now: now.addingTimeInterval(60))
    check(clock.liveAt == now.addingTimeInterval(60), "back live, a drop counts again")

    var idle = LiveClock()
    idle.reconnecting(live: false)
    idle.update(wasLive: false, isLive: true, now: ago(2))
    idle.update(wasLive: true, isLive: false, now: ago(1))
    check(idle.liveAt == ago(1), "a reconnect while not live suspects nothing")
}

// The time next to a tab's title (#338).
do {
    let de = Locale(identifier: "de_DE")
    let two = [agent("t1", .working, since: ago(5)), agent("t2", .working, since: ago(9)), agent("t3", .blocked, since: ago(20))]
    check(TabTime.since(state: .working, agents: two, board: nil) == ago(9), "earliest start of the same state")
    check(TabTime.since(state: .blocked, agents: two, board: nil) == ago(20), "other state does not count")
    for state in [WidgetSnapshot.State.idle, .done, .unknown] {
        check(TabTime.since(state: state, agents: [agent("x", state, since: ago(5))], board: nil) == nil, "no time for \(state)")
    }
    let unknown = [agent("b1", .blocked)]
    check(TabTime.since(state: .blocked, agents: unknown, board: nil) == nil, "no start known")
    check(TabTime.since(state: .blocked, agents: unknown, board: board("K", updated: now, [agent("b1", .blocked, since: ago(7))])) == ago(7), "start from the board")
    check(TabTime.since(state: .blocked, agents: unknown, board: board("K", updated: now, [agent("b1", .working, since: ago(7))])) == nil, "board in another state")
    check(TabTime.since(state: .blocked, agents: unknown, board: board("K", updated: now, [agent("other", .blocked, since: ago(7))])) == nil, "board of another pane")

    check(TabTime.label(since: ago(0.5), now: now, locale: de) == nil, "under a minute")
    check(TabTime.label(since: ago(12.9), now: now, locale: de) == "12 Min.", "whole minutes, rounded down")
    check(TabTime.label(since: ago(119), now: now, locale: de) == "1 Std.", "whole hours, rounded down")
    check(TabTime.label(since: ago(-5), now: now, locale: de) == nil, "start in the future")
}

// The board (#345): always the three columns, pinned agents at the top of their state's column.
do {
    let empty = AgentBoard(AgentOverview(hosts: [], boards: []))
    check(empty.columns.map(\.group) == [.waiting, .working, .done], "board has three columns, also without agents")
    check(empty.columns.allSatisfy { $0.rows.isEmpty }, "empty columns")

    let a = host("a", live: true, pinned: ["a3"], [
        agent("a1", .working, since: ago(3)), agent("a2", .blocked, since: ago(1)),
        agent("a3", .working, since: ago(9)), agent("a4", .idle, since: ago(2)),
    ])
    let b = host("b", live: true, [agent("b1", .done, since: ago(2)), agent("b2", .blocked, since: ago(5))])
    let board = AgentBoard(AgentOverview(hosts: [a, b], boards: []))
    func ids(_ group: AgentOverview.Group) -> [String] {
        board.columns.first { $0.group == group }?.rows.map(\.agent.paneID) ?? []
    }
    check(ids(.waiting) == ["a2", "b2"], "waiting column from both hosts")
    check(ids(.working) == ["a3", "a1"], "pinned agent first in its state's column")
    check(ids(.done) == ["b1"], "done column")
    check(!board.columns.flatMap(\.rows).contains { $0.agent.paneID == "a4" }, "no idle column")

    let c = host("c", live: true, pinned: ["c1", "c2"], [agent("c1", .idle, since: ago(2)), agent("c2", .unknown)])
    let pinnedReady = AgentBoard(AgentOverview(hosts: [c], boards: []))
    check(pinnedReady.columns.first { $0.group == .done }?.rows.count == 2, "pinned ready and unknown agents stay on the board")
}

// When the board reads a screen (#345).
do {
    func due(_ state: WidgetSnapshot.State, _ last: (WidgetSnapshot.State, Double)?) -> Bool {
        BoardRead.due(state: state, last: last.map { ($0.0, now.addingTimeInterval(-$0.1)) }, now: now)
    }
    check(due(.working, nil), "first reading")
    check(due(.blocked, (.working, 1)), "state changed")
    check(!due(.working, (.working, 29)), "working, read 29 s ago")
    check(due(.working, (.working, 30)), "working, read 30 s ago")
    check(!due(.done, (.done, 3600)), "done is read once")
    check(!due(.blocked, (.blocked, 3600)), "waiting is read once")
}

if failures > 0 { exit(1) }
print("agent-overview: ok")
