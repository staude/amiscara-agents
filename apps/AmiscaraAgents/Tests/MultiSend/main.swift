// Checks which agents one prompt to several can go to (#299) without the
// UI: the reason an agent cannot be picked and the quick selections.
// Built by scripts/multi-send-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

let host = UUID()

func target(_ pane: String, _ state: WidgetSnapshot.State, live: Bool = true, input: Bool = true) -> MultiSend.Target {
    let agent = WidgetSnapshot.Agent(paneID: pane, workspaceID: "w-\(pane)", place: "Space · Tab", name: "claude", state: state)
    return MultiSend.Target(hostID: host, hostName: "mac", agent: agent, live: live, inputAllowed: input)
}

func ids(_ panes: String...) -> Set<String> {
    Set(panes.map { "\(host.uuidString)|\($0)" })
}

// Why an agent cannot be picked.
do {
    check(target("a", .done).blockedReason == nil, "a finished agent can be picked")
    check(target("a", .blocked).blockedReason == "Wartet auf Antwort", "a waiting agent cannot")
    check(target("a", .done, live: false).blockedReason == "Keine Verbindung", "nor one without a connection")
    check(target("a", .done, input: false).blockedReason == "Eingabe aus", "nor one with input off")
    check(target("a", .blocked, live: false, input: false).blockedReason == "Wartet auf Antwort", "waiting is named first")
    check(target("a", .working, live: false, input: false).blockedReason == "Keine Verbindung", "then the connection")
    check(target("a", .idle).id == "\(host.uuidString)|a", "id from host and pane")
}

// The quick selections (done 1); waiting agents are never picked.
do {
    let targets = [
        target("blocked", .blocked),
        target("working", .working),
        target("done", .done),
        target("idle", .idle),
        target("unknown", .unknown),
        target("offline", .done, live: false),
        target("inputOff", .working, input: false),
    ]
    check(MultiSend.select(.finished, in: targets) == ids("done", "idle"), "finished: done and ready")
    check(MultiSend.select(.working, in: targets) == ids("working"), "working")
    check(MultiSend.select(.all, in: targets) == ids("working", "done", "idle", "unknown"), "all with unknown, without the ones not to pick")
    check(MultiSend.select(.all, in: [target("b", .blocked)]).isEmpty, "only waiting: nothing")
}

if failures > 0 { exit(1) }
print("multi-send: ok")
