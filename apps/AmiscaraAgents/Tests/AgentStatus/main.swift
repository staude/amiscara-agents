// Checks the answer of "Was macht der Agent?" (#275) without the UI: the
// screen lines it picks, the clock of state changes and the texts. Built by
// scripts/agent-status-test.sh.
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

// MARK: State clock

let t0 = Date(timeIntervalSince1970: 1_000_000)
var clock = StateClock()
clock.observe([(paneID: "p1", state: .working)], at: t0, continuous: false)
check(clock.entry("p1") == .init(state: .working, since: t0, exact: false), "first update is not exact")

clock.observe([(paneID: "p1", state: .working)], at: t0 + 30, continuous: true)
check(clock.entry("p1")?.since == t0, "same state keeps its start")

clock.observe([(paneID: "p1", state: .blocked), (paneID: "p2", state: .idle)], at: t0 + 60, continuous: true)
check(clock.entry("p1") == .init(state: .blocked, since: t0 + 60, exact: true), "a change seen live is exact")
check(clock.entry("p2")?.exact == true, "a new pane seen live is exact")

clock.observe([(paneID: "p1", state: .done)], at: t0 + 600, continuous: false)
check(clock.entry("p1") == .init(state: .done, since: t0 + 600, exact: false), "a change after a gap is not exact")
check(clock.entry("p2") == nil, "a pane that is gone is forgotten")

// MARK: Texts

let now = t0 + 3600
let live = AgentStatusText.text(
    name: "claude", space: "Shop", status: "arbeitet", since: now - 5 * 60, exact: true, now: now,
    lines: ["a", "b", "c"], source: .live, linesMissingOffline: false
)
check(live.hasPrefix("claude in Shop: arbeitet, seit "), "live text: \(live)")
check(live.contains("5"), "live text has the duration: \(live)")
check(!live.contains("mindestens"), "exact duration has no 'mindestens': \(live)")
check(live.hasSuffix("Auf dem Bildschirm: a / b / c"), "live text ends with the lines: \(live)")

let inexact = AgentStatusText.text(
    name: "claude", space: "Shop", status: "wartet", since: now - 2 * 3600, exact: false, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(inexact.contains("seit mindestens"), "inexact duration says 'mindestens': \(inexact)")
check(!inexact.contains("Bildschirm"), "no lines, no lines part: \(inexact)")

let fresh = AgentStatusText.text(
    name: "claude", space: "Shop", status: "fertig", since: now - 20, exact: false, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(fresh == "claude in Shop: fertig.", "inexact under a minute has no duration: \(fresh)")

let justNow = AgentStatusText.text(
    name: "claude", space: "", status: "fertig", since: now - 20, exact: true, now: now,
    lines: [], source: .live, linesMissingOffline: false
)
check(justNow == "claude: fertig, gerade eben gewechselt.", "exact under a minute says 'gerade eben': \(justNow)")

let mac = AgentStatusText.text(
    name: "claude", space: "Shop", status: "arbeitet", since: nil, exact: false, now: now,
    lines: [], source: .mac(updated: now - 3 * 60), linesMissingOffline: true
)
check(mac.hasPrefix("Laut Mac (Stand vor "), "Mac text names its source: \(mac)")
check(mac.contains("claude in Shop: arbeitet."), "Mac text without a start has no duration: \(mac)")
check(mac.hasSuffix("Bildschirmzeilen gibt es ohne Verbindung nur für wartende Agents."), "Mac text says why lines are missing: \(mac)")

let macNow = AgentStatusText.text(
    name: "claude", space: "Shop", status: "wartet", since: now - 10 * 60, exact: true, now: now,
    lines: ["Proceed?"], source: .mac(updated: now - 5), linesMissingOffline: false
)
check(macNow.hasPrefix("Laut Mac (Stand gerade eben): claude in Shop: wartet, seit "), "fresh Mac board: \(macNow)")
check(macNow.hasSuffix("Auf dem Bildschirm: Proceed?"), "waiting agent offline has lines: \(macNow)")

// Done item 3 of #275: without data a clear message, no failure.
let none = AgentStatusText.noData(name: "claude")
check(none.hasPrefix("Zu claude liegen gerade keine Daten vor."), "no data message: \(none)")

if failures > 0 { exit(1) }
print("agent-status: ok")
