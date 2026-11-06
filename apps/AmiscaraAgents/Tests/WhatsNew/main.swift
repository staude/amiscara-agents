// Checks the rules of "Neuigkeiten" (#341) without the UI: version order,
// what shows after an update, the history and the bundled file. Built by
// scripts/whats-new-test.sh from the repository root.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func entry(_ version: String) -> WhatsNewEntry {
    WhatsNewEntry(version: version, de: ["de \(version)"], en: ["en \(version)"])
}

func versions(_ entries: [WhatsNewEntry]) -> [String] { entries.map(\.version) }

// Order: numbers, not text.
check(WhatsNew.isOlder(WhatsNew.parse("0.9.0")!, than: WhatsNew.parse("0.10.0")!), "0.9.0 before 0.10.0")
check(!WhatsNew.isOlder(WhatsNew.parse("1.0.0")!, than: WhatsNew.parse("0.10.0")!), "1.0.0 after 0.10.0")
check(WhatsNew.parse("1.2") == nil, "two numbers are unreadable")
check(WhatsNew.parse("1.2.x") == nil, "letters are unreadable")
check(WhatsNew.parse("1.2.+3") == nil, "signs are unreadable")

let all = [entry("0.1.0"), entry("0.3.0"), entry("0.2.0"), entry("0.10.0"), entry("kaputt")]

// pending: after seen, up to current, newest first.
check(versions(WhatsNew.pending(all, seen: "0.2.0", current: "0.3.0")) == ["0.3.0"], "one step")
check(versions(WhatsNew.pending(all, seen: "0.1.0", current: "0.10.0")) == ["0.10.0", "0.3.0", "0.2.0"], "several steps, newest first")
check(WhatsNew.pending(all, seen: "0.3.0", current: "0.3.0").isEmpty, "same version shows nothing")
check(WhatsNew.pending(all, seen: "0.3.0", current: "0.2.0").isEmpty, "downgrade shows nothing")
check(WhatsNew.pending(all, seen: "?", current: "0.3.0").isEmpty, "unreadable seen version shows nothing")
check(versions(WhatsNew.pending(all, seen: "0.3.0", current: "0.4.0")).isEmpty, "a version without notes shows nothing")

// history: everything up to the installed version.
check(versions(WhatsNew.history(all, current: "0.3.0")) == ["0.3.0", "0.2.0", "0.1.0"], "history up to current")
check(WhatsNew.history(all, current: "x").isEmpty, "unreadable current version has no history")

// The start: first start, then an update, then the same version, a downgrade.
let suite = "whats-new-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(WhatsNew.onLaunch(all, current: "0.2.0", defaults: defaults).isEmpty, "first start shows nothing")
check(defaults.string(forKey: WhatsNew.seenKey) == "0.2.0", "first start notes the version")
check(versions(WhatsNew.onLaunch(all, current: "0.3.0", defaults: defaults)) == ["0.3.0"], "update shows the new version")
check(WhatsNew.onLaunch(all, current: "0.3.0", defaults: defaults).isEmpty, "second start shows nothing")
check(WhatsNew.onLaunch(all, current: "0.2.0", defaults: defaults).isEmpty, "downgrade shows nothing")
check(defaults.string(forKey: WhatsNew.seenKey) == "0.2.0", "downgrade notes the version")

// The file the app bundles, with an entry it cannot read.
let file = URL(fileURLWithPath: "apps/whats-new.json")
let mac = WhatsNew.entries(from: file, app: "mac")
check(!mac.isEmpty, "apps/whats-new.json has mac entries")
check(mac.allSatisfy { WhatsNew.parse($0.version) != nil && !$0.de.isEmpty && !$0.en.isEmpty }, "mac entries are complete")
check(!WhatsNew.entries(from: file, app: "desktop").isEmpty, "apps/whats-new.json has desktop entries")
check(WhatsNew.entries(from: nil, app: "mac").isEmpty, "a missing file has no entries")
let broken = FileManager.default.temporaryDirectory.appending(path: "whats-new-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: broken) }
try! #"{"mac": [{"version": "0.2.0", "de": ["a"]}, {"version": "0.1.0", "de": ["b"], "en": ["c"]}, 7]}"#
    .write(to: broken, atomically: true, encoding: .utf8)
check(versions(WhatsNew.entries(from: broken, app: "mac")) == ["0.1.0"], "skips unreadable entries")
try! "{".write(to: broken, atomically: true, encoding: .utf8)
check(WhatsNew.entries(from: broken, app: "mac").isEmpty, "broken JSON has no entries")

if failures > 0 { exit(1) }
print("whats-new: ok")
