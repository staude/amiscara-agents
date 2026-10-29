import Foundation

/// Sums of Claude Code tokens for the dashboard and the 30-day page
/// (#302), by local day, model and folder. Kept apart from `UsageStore`
/// so `scripts/usage-sums-test.sh` builds it with the bindings alone.
enum UsageSums {
    static let historyDays = 30

    /// Start of the first day of the history.
    static func historyStart(now: Date = .now) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
    }

    /// Claude Code's folder name for a working directory, as in the core
    /// (`claude::project_dir`): directories that share it share their
    /// usage, which the core reports under the first of them.
    static func projectFolder(_ cwd: String) -> String {
        // By scalar like Rust's `chars()`, not by grapheme cluster.
        String(String.UnicodeScalarView(cwd.unicodeScalars.map {
            $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) ? $0 : "-"
        }))
    }

    /// The sum of the buckets in `[from, to)`, for one project folder or all.
    @MainActor
    static func sum(_ buckets: [UsageBucket], from: Date, to: Date = .distantFuture, folder: String? = nil,
                    prices: UsagePrices) -> WidgetSnapshot.Usage {
        var usage = WidgetSnapshot.Usage()
        for bucket in buckets where folder == nil || projectFolder(bucket.cwd) == folder {
            let start = bucket.start
            guard start >= from, start < to else { continue }
            let tokens = UsageTokens(bucket)
            usage.tokens += tokens.total
            if let cost = prices.cost(model: bucket.model, tokens: tokens) {
                usage.cost += cost
            } else if tokens.total > 0 {
                usage.unpriced = true
            }
        }
        return usage
    }

    struct Day: Identifiable {
        let date: Date
        let usage: WidgetSnapshot.Usage
        let parts: [Part]
        var id: Date { date }
    }

    struct Part: Identifiable {
        let model: String
        let folder: String
        let usage: WidgetSnapshot.Usage
        var id: String { model + "\n" + folder }
    }

    /// The days with tokens, newest first; each split by model and folder,
    /// most tokens first.
    @MainActor
    static func days(_ buckets: [UsageBucket], prices: UsagePrices) -> [Day] {
        let calendar = Calendar.current
        let start = historyStart()
        let byDay = Dictionary(grouping: buckets.filter { $0.start >= start }) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted(by: >).compactMap { date in
            let buckets = byDay[date] ?? []
            let end = calendar.date(byAdding: .day, value: 1, to: date) ?? .distantFuture
            let usage = sum(buckets, from: date, to: end, prices: prices)
            guard usage.tokens > 0 else { return nil }
            let parts = Dictionary(grouping: buckets) { "\($0.model)\n\($0.cwd)" }.values.compactMap { group -> Part? in
                guard let first = group.first else { return nil }
                return Part(
                    model: first.model,
                    folder: first.cwd,
                    usage: sum(group, from: date, to: end, prices: prices)
                )
            }
            return Day(date: date, usage: usage, parts: parts.sorted { $0.usage.tokens > $1.usage.tokens })
        }
    }
}

extension UsageBucket {
    var start: Date { Date(timeIntervalSince1970: TimeInterval(hourStartMs) / 1000) }
}
