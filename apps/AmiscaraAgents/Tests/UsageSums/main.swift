// Checks the token sums (#302) with the real bindings: folder names as the
// core makes them, sums per day with and without prices, the 30-day split
// by model and folder. Built by scripts/usage-sums-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func bucket(_ cwd: String, _ start: Date, _ model: String, input: UInt64 = 0, output: UInt64 = 0,
            write5m: UInt64 = 0, write1h: UInt64 = 0, read: UInt64 = 0) -> UsageBucket {
    UsageBucket(cwd: cwd, hourStartMs: UInt64(start.timeIntervalSince1970 * 1000), model: model,
                input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read)
}

@MainActor func run() {
    // As `project_dir_like_claude_code` in herdr-core, without the prefix.
    check(UsageSums.projectFolder("/Users/me/dev/shop/.claude/worktrees/x_y")
          == "-Users-me-dev-shop--claude-worktrees-x-y", "folder like the core")
    // Rust goes by scalar: a decomposed "ä" and a flag are two each.
    check(UsageSums.projectFolder("/x/a\u{0308}") == "-x-a-", "combining mark by scalar")
    check(UsageSums.projectFolder("/x/🇩🇪") == "-x---", "flag by scalar")
    check(UsageSums.projectFolder("/x/ä1") == "-x--1", "non-ASCII letter, digit kept")

    let defaults = UserDefaults(suiteName: "usage-sums-test")!
    defaults.removePersistentDomain(forName: "usage-sums-test")
    let prices = UsagePrices(defaults: defaults)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let hour: TimeInterval = 3600
    let buckets = [
        bucket("/a", today.addingTimeInterval(hour), "claude-opus-5-5", input: 1_000_000, output: 1_000_000),
        bucket("/a", today.addingTimeInterval(2 * hour), "claude-opus-5-5-20261001", write5m: 1_000_000, write1h: 1_000_000, read: 1_000_000),
        bucket("/b", today.addingTimeInterval(hour), "claude-unknown", input: 500),
        bucket("/a", yesterday.addingTimeInterval(hour), "claude-sonnet-5-5", output: 1_000_000),
        bucket("/a_b", today.addingTimeInterval(hour), "claude-haiku-5-5", input: 1_000_000),
    ]

    // Opus 5.5: 4 + 20, then 5 + 8 + 0.20 per million.
    let a = UsageSums.sum(buckets, from: today, folder: UsageSums.projectFolder("/a"), prices: prices)
    check(a.tokens == 5_000_000, "tokens of /a today: \(a.tokens)")
    check(abs(a.cost - 37.2) < 1e-9, "cost of /a today: \(a.cost)")
    check(!a.unpriced, "/a fully priced")

    let b = UsageSums.sum(buckets, from: today, folder: UsageSums.projectFolder("/b"), prices: prices)
    check(b.tokens == 500 && b.cost == 0 && b.unpriced, "model without price")
    check(b.summary.contains("~") == false, "no estimate without any price: \(b.summary)")

    // /a-b shares the core's folder with /a_b.
    let shared = UsageSums.sum(buckets, from: today, folder: UsageSums.projectFolder("/a-b"), prices: prices)
    check(shared.tokens == 1_000_000 && abs(shared.cost - 0.1) < 1e-9, "shared project folder")

    let all = UsageSums.sum(buckets, from: today, prices: prices)
    check(all.tokens == 6_000_500 && all.unpriced, "host total today")

    // A changed price changes the estimate.
    prices.prices[1].output = 40
    let dearer = UsageSums.sum(buckets, from: today, folder: UsageSums.projectFolder("/a"), prices: prices)
    check(abs(dearer.cost - 57.2) < 1e-9, "changed price: \(dearer.cost)")
    prices.reset()
    check(prices.isDefault && defaults.data(forKey: UsagePrices.storageKey) == nil, "reset drops the stored table")

    let days = UsageSums.days(buckets, prices: prices)
    check(days.map(\.date) == [today, yesterday], "days newest first: \(days.map(\.date))")
    check(days.first?.usage.tokens == 6_000_500, "today in the history")
    check(abs((days.last?.usage.cost ?? 0) - 10) < 1e-9, "yesterday's Sonnet output")
    let parts = days.first?.parts ?? []
    check(parts.count == 4, "today split by model and folder: \(parts.count)")
    check(parts.first?.usage.tokens ?? 0 >= parts.last?.usage.tokens ?? 0, "parts by tokens")

    let old = bucket("/a", calendar.date(byAdding: .day, value: -40, to: today)!, "claude-opus-5-5", input: 1)
    check(UsageSums.days([old], prices: prices).isEmpty, "older than 30 days left out")
}

MainActor.assumeIsolated { run() }
if failures > 0 {
    print("usage-sums: \(failures) failed")
    exit(1)
}
print("usage-sums: ok")
