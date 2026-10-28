// Checks the per-pane visit memory (#273) without the UI: the tail ignores
// blank lines and edge spaces, new lines follow the last anchor, record,
// reload, forget a host, entries expire after a week. Built by
// scripts/pane-visits-test.sh.
import Foundation

enum DemoMode { static let isOn = false }

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@MainActor func run() {
    // Tail
    check(PaneVisits.tail(of: "a\n\n  b  \n\n") == PaneVisits.tail(of: "a\nb"), "tail ignores blank lines and edge spaces")
    check(PaneVisits.tail(of: "a\nb") != PaneVisits.tail(of: "a\nc"), "tail sees a changed line")
    let long = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
    check(PaneVisits.tail(of: long).count == PaneVisits.tailLines, "tail keeps the last lines")
    check(PaneVisits.tail(of: long) == PaneVisits.tail(of: (11 ... 30).map { "line \($0)" }.joined(separator: "\n")), "tail is the newest lines")
    check(PaneVisits.tail(of: "").isEmpty, "empty screen has no tail")

    // New lines
    let tail = PaneVisits.tail(of: "$ make\nbuilt")
    check(PaneVisits.newLines(in: "old\n$ make\n\nbuilt\n$ test\nok", after: tail) == ["", "built", "$ test", "ok"], "lines after the anchor, its bottom line again")
    check(PaneVisits.newLines(in: "$ make\nbuilt\nx\n$ make\nbuilt\ny", after: tail) == ["built", "y"], "the last of two anchors")
    check(PaneVisits.newLines(in: "a\nb", after: tail) == ["a", "b"], "no anchor gives everything")
    check(PaneVisits.newLines(in: "a\nb", after: []) == ["a", "b"], "no tail gives everything")
    check(PaneVisits.newLines(in: "$ make\nbuilt", after: tail) == ["built"], "nothing new but the bottom line")
    let atPrompt = PaneVisits.tail(of: "built\n% ")
    check(PaneVisits.newLines(in: "built\n% make\nok", after: atPrompt) == ["% make", "ok"], "a prompt line typed into since")

    // New output
    check(PaneVisits.newOutput(in: "$ make\nbuilt", after: tail).isEmpty, "unchanged screen has no new output")
    check(PaneVisits.newOutput(in: "$ make\nbuilt 12:05", after: tail).isEmpty, "a changed bottom line alone is no new output")
    check(PaneVisits.newOutput(in: "$ make\nbuilt\n$ test\nok", after: tail) == ["built", "$ test", "ok"], "new lines after the anchor")
    check(PaneVisits.newOutput(in: "x\ny", after: tail) == ["x", "y"], "no anchor gives everything")

    // Memory
    let file = FileManager.default.temporaryDirectory.appending(path: "pane-visits-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let hostA = UUID(), hostB = UUID()
    let now = Date.now

    let visits = PaneVisits(fileURL: file)
    check(visits.entry(host: hostA, pane: "p1") == nil, "unknown pane has no entry")
    visits.record(host: hostA, pane: "p1", tail: tail, seen: now)
    visits.record(host: hostA, pane: "p2", tail: [], seen: now.addingTimeInterval(-8 * 24 * 60 * 60))
    visits.record(host: hostB, pane: "p1", tail: [], seen: now)
    check(visits.entry(host: hostA, pane: "p1") == .init(seen: now, tail: tail), "records seen and tail")

    let reloaded = PaneVisits(fileURL: file, now: now)
    check(reloaded.entry(host: hostA, pane: "p1")?.tail == tail, "survives a restart")
    check(reloaded.entry(host: hostA, pane: "p2") == nil, "drops visits older than a week")

    reloaded.forget(host: hostA)
    check(reloaded.entry(host: hostA, pane: "p1") == nil, "forgets the removed host")
    check(reloaded.entry(host: hostB, pane: "p1") != nil, "keeps other hosts")
    check(PaneVisits(fileURL: file).entry(host: hostA, pane: "p1") == nil, "forgetting is saved")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("pane-visits: ok")
