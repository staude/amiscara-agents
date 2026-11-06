// Checks the put away tabs (#333) without the UI and without iCloud: put
// away, bring back, forget tabs the host no longer has, key length. Built
// by scripts/settled-tabs-test.sh.
import Foundation

enum DemoMode { static let isOn = false }

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@MainActor func run() {
    let hostA = "SHA256:abc|", hostB = "device|\(UUID().uuidString)"
    let tabs = SettledTabs(backing: nil)
    check(tabs.tabs(host: hostA).isEmpty, "nothing put away at first")

    tabs.settle(tab: "w1:t2", host: hostA)
    tabs.settle(tab: "w1:t3", host: hostA)
    tabs.settle(tab: "w1:t2", host: hostB)
    check(tabs.contains(tab: "w1:t2", host: hostA), "puts a tab away")
    check(tabs.tabs(host: hostA) == ["w1:t2", "w1:t3"], "keeps several tabs per host")
    check(!tabs.contains(tab: "w1:t4", host: hostA), "other tabs stay")

    tabs.unsettle(tab: "w1:t2", host: hostA)
    check(!tabs.contains(tab: "w1:t2", host: hostA), "brings a tab back")
    check(tabs.contains(tab: "w1:t2", host: hostB), "hosts are separate")

    tabs.settle(tab: "w2:t1", host: hostA)
    tabs.settle(tab: "w2:t2", host: hostA)
    tabs.unsettleAll(host: hostA, tabs: ["w2:t1", "w2:t2"])
    check(tabs.tabs(host: hostA) == ["w1:t3"], "brings back all tabs of a space")

    tabs.settle(tab: "w3:t1", host: hostA)
    tabs.prune(host: hostA, keeping: ["w3:t1", "w1:t9"])
    check(tabs.tabs(host: hostA) == ["w3:t1"], "forgets tabs the host no longer has")

    tabs.settle(tab: "w4:t1", host: hostA)
    tabs.settle(tab: "w4:t2", host: hostA)
    tabs.revive(host: hostA, tabs: [("w3:t1", false), ("w4:t1", true), ("w4:t2", false)], complete: false)
    check(tabs.tabs(host: hostA) == ["w3:t1", "w4:t2"], "a waiting agent brings its tab back")
    tabs.revive(host: hostA, tabs: [("w4:t2", false)], complete: false)
    check(tabs.tabs(host: hostA) == ["w3:t1", "w4:t2"], "an incomplete update forgets nothing")
    tabs.revive(host: hostA, tabs: [("w4:t2", false)], complete: true)
    check(tabs.tabs(host: hostA) == ["w4:t2"], "a complete update forgets tabs the host no longer has")
    tabs.revive(host: hostA, tabs: [("w4:t2", false)], complete: true)
    check(tabs.tabs(host: hostA) == ["w4:t2"], "a tab that does not wait stays away")

    tabs.prune(host: hostA, keeping: [])
    check(tabs.tabs(host: hostA).isEmpty, "an empty host keeps nothing")

    let long = String(repeating: "SHA256:xyz", count: 20) + "|/home/someone/.config/herdr/sessions/test/herdr.sock"
    let key = SettledTabs.storageKey(host: long)
    check(key.utf8.count <= 64, "keys fit the key-value store")
    check(key.hasPrefix(SettledTabs.keyPrefix), "keys share the prefix")
    check(key == SettledTabs.storageKey(host: long), "keys are stable")
    check(key != SettledTabs.storageKey(host: hostA), "keys differ per host")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("settled-tabs: ok")
