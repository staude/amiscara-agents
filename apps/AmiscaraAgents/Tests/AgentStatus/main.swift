// Checks the answer of "Was macht der Agent?" (#275) without the UI: the
// screen lines it picks and the texts. Built by scripts/agent-status-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// MARK: Screen lines

let claudeScreen = """
⏺ I updated the parser and ran the tests.

  ⎿  All 42 tests passed

⏺ Next I will look at the config loader.
  Reading src/config.rs

╭──────────────────────────────────────────────╮
│ >                                            │
╰──────────────────────────────────────────────╯
  ? for shortcuts                ⏵⏵ accept edits on (shift+tab to cycle)

"""
check(ScreenLines.last(3, of: claudeScreen) == [
    "⎿  All 42 tests passed",
    "Next I will look at the config loader.",
    "Reading src/config.rs",
], "drops input box, footer and empty rows: \(ScreenLines.last(3, of: claudeScreen))")
check(ScreenLines.last(1, of: claudeScreen) == ["Reading src/config.rs"], "keeps the last rows")
check(ScreenLines.last(3, of: "") == [], "empty screen has no lines")
check(ScreenLines.last(3, of: "│ Do you want to proceed? │\n│ ❯ 1. Yes │") == ["Do you want to proceed?", "❯ 1. Yes"],
      "strips the frame of a question")
check(ScreenLines.isChrome("? for shortcuts"), "footer is chrome")
check(ScreenLines.isChrome("│ > │"), "prompt is chrome")
check(!ScreenLines.isChrome("> quoted output"), "text after a > is not chrome")

let t0 = Date(timeIntervalSince1970: 1_000_000)

// MARK: Texts

let now = t0 + 3600
let live = AgentStatusText.text(
    name: "claude", space: "Shop", status: "arbeitet", since: now - 5 * 60, now: now,
    lines: ["a", "b", "c"], source: .live, linesMissingOffline: false
)
check(live.hasPrefix("claude in Shop: arbeitet, schon "), "live text: \(live)")
check(live.contains("5"), "live text has the duration: \(live)")
check(live.hasSuffix("Auf dem Bildschirm: a / b / c"), "live text ends with the lines: \(live)")

let noLines = AgentStatusText.text(
    name: "claude", space: "Shop", status: "wartet", since: now - 2 * 3600, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(noLines.contains("schon 2"), "hours as duration: \(noLines)")
check(!noLines.contains("Bildschirm"), "no lines, no lines part: \(noLines)")

let unknown = AgentStatusText.text(
    name: "claude", space: "Shop", status: "fertig", since: nil, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(unknown == "claude in Shop: fertig.", "unknown start has no duration: \(unknown)")

let justNow = AgentStatusText.text(
    name: "claude", space: "", status: "fertig", since: now - 20, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(justNow == "claude: fertig, gerade eben gewechselt.", "under a minute says 'gerade eben': \(justNow)")

let mac = AgentStatusText.text(
    name: "claude", space: "Shop", status: "arbeitet", since: nil, now: now,
    lines: [], source: .mac(updated: now - 3 * 60), linesMissingOffline: true
)
check(mac.hasPrefix("Laut Mac (Stand vor "), "Mac text names its source: \(mac)")
check(mac.contains("claude in Shop: arbeitet."), "Mac text without a start has no duration: \(mac)")
check(mac.hasSuffix("Bildschirmzeilen gibt es ohne Verbindung nur für wartende Agents."), "Mac text says why lines are missing: \(mac)")

let macNow = AgentStatusText.text(
    name: "claude", space: "Shop", status: "wartet", since: now - 10 * 60, now: now,
    lines: ["Proceed?"], source: .mac(updated: now - 5), linesMissingOffline: false
)
check(macNow.hasPrefix("Laut Mac (Stand gerade eben): claude in Shop: wartet, schon "), "fresh Mac board: \(macNow)")
check(macNow.hasSuffix("Auf dem Bildschirm: Proceed?"), "waiting agent offline has lines: \(macNow)")

// Done item 3 of #275: without data a clear message, no failure.
let none = AgentStatusText.noData(name: "claude")
check(none.hasPrefix("Zu claude liegen gerade keine Daten vor."), "no data message: \(none)")

if failures > 0 { exit(1) }
print("agent-status: ok")
