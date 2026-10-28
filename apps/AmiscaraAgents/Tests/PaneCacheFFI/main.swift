// Checks the memory side of the last pane screens (#276) with the real
// bindings: rows cut to 500, the screen and title back after a restart,
// the title from disk kept on the next screen, nothing kept after forget,
// lastOpen in the defaults. Built by scripts/pane-cache-ffi-test.sh.
import Foundation

enum DemoMode { static let isOn = false }

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func screen(_ pane: String, rows: Int, text: String = "row") -> PaneContent {
    let span = StyledSpan(
        text: text, width: UInt32(text.count), fg: .rgb(r: 1, g: 2, b: 3), bg: .default,
        bold: true, dim: false, italic: false, underline: false, inverse: false,
        hidden: false, strikethrough: false, link: "https://example.com"
    )
    let lines = (0..<rows).map { index in
        StyledLine(spans: [StyledSpan(
            text: "\(text) \(index)", width: span.width, fg: span.fg, bg: span.bg,
            bold: span.bold, dim: span.dim, italic: span.italic, underline: span.underline,
            inverse: span.inverse, hidden: span.hidden, strikethrough: span.strikethrough, link: span.link
        )])
    }
    return PaneContent(paneId: pane, lines: lines, truncated: true, historyLines: 1000, question: ChoiceQuestion(options: [ChoiceOption(key: "1", label: "Yes")]))
}

@MainActor func run() {
    let directory = FileManager.default.temporaryDirectory.appending(path: "pane-cache-ffi-\(UUID().uuidString)")
    let suite = "pane-cache-ffi-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
    let hostA = UUID(), hostB = UUID()

    let cache = PaneCache(directory: directory, defaults: defaults)
    check(cache.entry(host: hostA, pane: "p1") == nil, "unknown pane has no screen")

    cache.setTitle("claude", host: hostA, pane: "p1")
    cache.record(screen("p1", rows: 700), host: hostA, pane: "p1")
    let kept = cache.entry(host: hostA, pane: "p1")
    check(kept?.content.lines.count == PaneCache.maxLines, "keeps the last 500 rows")
    check(kept?.content.lines.last?.spans.first?.text == "row 699", "keeps the newest rows")
    check(kept?.content.historyLines == 0 && kept?.content.truncated == false, "a kept screen asks for no history")
    check(kept?.content.question == nil, "a kept screen offers no answers")
    check(kept?.title == "claude", "a title seen before the screen is kept")
    cache.record(screen("p2", rows: 3), host: hostB, pane: "p2")
    cache.lastOpen = .init(host: hostA, workspace: "w1", pane: "p1", spaceName: "docs")
    cache.flush()

    let restarted = PaneCache(directory: directory, defaults: defaults)
    let read = restarted.entry(host: hostA, pane: "p1")
    check(read?.content == kept?.content, "the screen survives a restart")
    check(read?.title == "claude", "the title survives a restart")
    check(read?.date == kept?.date, "the time survives a restart")
    check(restarted.lastOpen?.spaceName == "docs", "lastOpen survives a restart")

    restarted.record(screen("p1", rows: 2, text: "new"), host: hostA, pane: "p1")
    restarted.flush()
    let third = PaneCache(directory: directory, defaults: defaults)
    check(third.entry(host: hostA, pane: "p1")?.title == "claude", "a new screen keeps the title from disk")
    check(third.entry(host: hostA, pane: "p1")?.content.lines.count == 2, "a new screen replaces the old one")

    third.forget(host: hostA)
    third.record(screen("p1", rows: 1), host: hostA, pane: "p1")
    third.flush()
    check(third.entry(host: hostA, pane: "p1") == nil, "nothing is kept of a removed host")
    check(third.lastOpen == nil, "forgetting the host drops lastOpen")
    let fourth = PaneCache(directory: directory, defaults: defaults)
    check(fourth.entry(host: hostA, pane: "p1") == nil, "the removed host's files are gone")
    check(fourth.entry(host: hostB, pane: "p2") != nil, "other hosts stay")

    let memory = PaneCache(directory: nil, defaults: nil)
    memory.record(screen("m", rows: 1), host: hostA, pane: "m")
    memory.lastOpen = .init(host: hostA, workspace: "w", pane: nil, spaceName: "x")
    memory.flush()
    check(memory.entry(host: hostA, pane: "m") != nil, "the demo mode keeps screens in memory")
    check(PaneCache(directory: nil, defaults: nil).lastOpen == nil, "the demo mode writes nothing")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("pane-cache-ffi: ok")
