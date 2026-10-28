// Checks the files of the last pane screens (#276) without the UI: write,
// read back, reload, expiry after 7 days, the 41st pane pushing out the
// oldest, forget a host. Built by scripts/pane-cache-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

/// The time the files see; set by the test.
final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor func run() {
    let directory = FileManager.default.temporaryDirectory.appending(path: "pane-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let hostA = UUID(), hostB = UUID()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let clock = Clock(start)
    let files = PaneCacheFiles(directory: directory, now: { clock.now })

    check(files.read(host: hostA, pane: "w1:p1") == nil, "unknown pane has no screen")

    files.write("{\"a\":1}", title: "claude", host: hostA, pane: "w1:p1", date: clock.now)
    files.write("{\"b\":2}", title: nil, host: hostB, pane: "w1:p1", date: clock.now)
    let read = files.read(host: hostA, pane: "w1:p1")
    check(read?.json == "{\"a\":1}", "reads the screen back")
    check(read?.title == "claude", "reads the title back")
    check(read?.date == start, "reads the date back")
    check(files.read(host: hostB, pane: "w1:p1")?.title == nil, "hosts are kept apart")

    files.write("{\"a\":3}", title: "claude", host: hostA, pane: "w1:p1", date: clock.now)
    check(files.read(host: hostA, pane: "w1:p1")?.json == "{\"a\":3}", "a newer screen replaces the old one")

    let reloaded = PaneCacheFiles(directory: directory, now: { clock.now })
    check(reloaded.read(host: hostA, pane: "w1:p1")?.json == "{\"a\":3}", "survives a restart")

    let odd = "w/../p:1 ü"
    files.write("{}", title: nil, host: hostA, pane: odd, date: clock.now)
    check(files.read(host: hostA, pane: odd)?.json == "{}", "any pane ID makes a file name")

    clock.now = start.addingTimeInterval(PaneCacheFiles.maxAge + 60)
    check(files.read(host: hostA, pane: "w1:p1") == nil, "a screen older than 7 days is not read")
    files.write("{}", title: nil, host: hostA, pane: "fresh", date: clock.now)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    check(left.count == 1, "writing deletes screens older than 7 days (left \(left.count))")

    for index in 0..<PaneCacheFiles.maxFiles {
        clock.now = clock.now.addingTimeInterval(1)
        files.write("{\"n\":\(index)}", title: nil, host: hostB, pane: "p\(index)", date: clock.now)
    }
    check(files.read(host: hostA, pane: "fresh") == nil, "the 41st pane pushes out the oldest")
    check(files.read(host: hostB, pane: "p0") != nil, "the newest 40 stay")
    let count = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    check(count == PaneCacheFiles.maxFiles, "at most 40 files (found \(count))")

    files.write("{}", title: nil, host: hostA, pane: "a1", date: clock.now)
    files.forget(host: hostB)
    check(files.read(host: hostB, pane: "p5") == nil, "forgets the removed host")
    check(files.read(host: hostA, pane: "a1") != nil, "keeps other hosts")

    let demo = PaneCacheFiles(directory: nil)
    demo.write("{}", title: nil, host: hostA, pane: "d", date: .now)
    check(demo.read(host: hostA, pane: "d") == nil, "without a directory nothing is kept")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("pane-cache: ok")
