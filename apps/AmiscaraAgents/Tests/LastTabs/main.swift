// Checks the per-space tab memory (#263) without the UI: record, read back,
// reload from disk, forget a host. Built by scripts/last-tabs-test.sh.
import Foundation

enum DemoMode { static let isOn = false }

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@MainActor func run() {
    let file = FileManager.default.temporaryDirectory.appending(path: "last-tabs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let hostA = UUID(), hostB = UUID()

    let tabs = LastTabs(fileURL: file)
    check(tabs.entry(host: hostA, workspace: "w1") == nil, "unknown space has no entry")

    tabs.record(tab: "w1:t3", pane: "p7", host: hostA, workspace: "w1")
    tabs.record(tab: "w2:t1", pane: nil, host: hostA, workspace: "w2")
    tabs.record(tab: "w1:t1", pane: "p1", host: hostB, workspace: "w1")
    check(tabs.entry(host: hostA, workspace: "w1") == .init(tab: "w1:t3", pane: "p7"), "records tab and pane")
    check(tabs.entry(host: hostA, workspace: "w2") == .init(tab: "w2:t1", pane: nil), "records tab without pane")

    tabs.record(tab: "w1:t2", pane: "p4", host: hostA, workspace: "w1")
    check(tabs.entry(host: hostA, workspace: "w1")?.tab == "w1:t2", "a newer tab replaces the old one")

    let reloaded = LastTabs(fileURL: file)
    check(reloaded.entry(host: hostA, workspace: "w1") == .init(tab: "w1:t2", pane: "p4"), "survives a restart")

    reloaded.forget(host: hostA)
    check(reloaded.entry(host: hostA, workspace: "w1") == nil, "forgets the removed host")
    check(reloaded.entry(host: hostB, workspace: "w1") != nil, "keeps other hosts")
    check(LastTabs(fileURL: file).entry(host: hostA, workspace: "w2") == nil, "forgetting is saved")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("last-tabs: ok")
