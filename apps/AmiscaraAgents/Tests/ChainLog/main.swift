// Checks the chain log (#300) without the UI: newest first, the limit per
// host, reload, clear and forget a host. Built by scripts/chain-log-test.sh.
import Foundation

enum DemoMode { static let isOn = false }

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@MainActor func run() {
    let file = FileManager.default.temporaryDirectory.appending(path: "chain-log-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let hostA = UUID(), hostB = UUID()
    func entry(_ n: Int, _ outcome: ChainLog.Entry.Outcome = .sent) -> ChainLog.Entry {
        ChainLog.Entry(chainID: "0a1b2c", trigger: "planner", target: "main", text: "prompt \(n)", outcome: outcome, reason: outcome == .sent ? nil : "why", at: Date(timeIntervalSince1970: Double(n)))
    }

    let log = ChainLog(fileURL: file)
    check(log.entries(host: hostA).isEmpty, "a new host has no entries")
    log.record([], host: hostA)
    check(log.entries(host: hostA).isEmpty, "nothing recorded from no results")
    log.record([entry(1), entry(2, .failed)], host: hostA)
    log.record([entry(3, .skipped)], host: hostA)
    log.record([entry(9)], host: hostB)
    check(log.entries(host: hostA).map(\.text) == ["prompt 3", "prompt 2", "prompt 1"], "newest first")
    check(log.entries(host: hostA)[1].reason == "why", "keeps the reason")

    let reloaded = ChainLog(fileURL: file)
    check(reloaded.entries(host: hostA) == log.entries(host: hostA), "survives a restart")

    reloaded.record((10 ..< 10 + ChainLog.limit).map { entry($0) }, host: hostA)
    check(reloaded.entries(host: hostA).count == ChainLog.limit, "keeps the limit")
    check(reloaded.entries(host: hostA).first?.text == "prompt \(9 + ChainLog.limit)", "the newest stays")

    reloaded.clear(host: hostA)
    check(reloaded.entries(host: hostA).isEmpty, "clears a host")
    check(reloaded.entries(host: hostB).map(\.text) == ["prompt 9"], "keeps other hosts")
    reloaded.forget(host: hostB)
    check(ChainLog(fileURL: file).entries(host: hostB).isEmpty, "forgetting is saved")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("chain-log: ok")
