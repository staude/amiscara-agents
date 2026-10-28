import Foundation
import Observation

/// Token usage of Claude Code on one host (#302), read by the core from the
/// session files of the working directories of the open Claude agents
/// (SFTP over SSH, so it needs file access like uploads). Today's usage
/// comes when the dashboard opens and every two minutes while it is shown
/// or "Tageskosten im Widget" is on; the 30 days only on the detail page.
/// What the core has read is kept in the cache directory, so after a
/// restart only new lines are read.
@MainActor
@Observable
final class UsageStore {
    /// "Tageskosten im Widget", off by default.
    static let widgetKey = "usageInWidget"
    static let historyDays = 30
    private static let interval: Duration = .seconds(120)

    enum Phase: Equatable {
        case idle
        case loading
        /// The host has no file access.
        case filesOff
        case failed(String)
    }

    /// Since the start of the day it was read on.
    private(set) var today: [UsageBucket] = []
    /// When `today` was read; `nil` before the first time.
    private(set) var todayRead: Date?
    private(set) var phase = Phase.idle
    /// The last `historyDays` days; `nil` until the detail page asked.
    private(set) var history: [UsageBucket]?
    private(set) var historyPhase = Phase.idle
    /// Dashboards showing this host; while one is, today is kept current.
    @ObservationIgnored var visible = 0
    /// Called after today's usage changed, e.g. for the widget.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private weak var connection: HostConnection?
    /// The session start whose state was restored from the cache file.
    @ObservationIgnored private var restored: Int?
    @ObservationIgnored private var refreshing = false
    /// Asked for while a run was going, e.g. for a new agent's folder.
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    func attach(_ connection: HostConnection) {
        self.connection = connection
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                if self.visible > 0 || UserDefaults.standard.bool(forKey: Self.widgetKey) {
                    await self.refreshToday()
                }
            }
        }
    }

    /// The working directories of the Claude agents on the board, each once.
    static func claudeFolders(_ board: [BoardItem]) -> [String] {
        var seen = Set<String>()
        return board.filter { $0.agent == "claude" }
            .compactMap(\.cwd)
            .filter { seen.insert($0).inserted }
    }

    /// Reads today's usage again; a run already going is not repeated.
    func refreshToday() async {
        guard let connection else { return }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        guard connection.config.uploadAllowed else {
            phase = .filesOff
            return
        }
        guard connection.isLive else { return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refreshToday() }
            }
        }
        let cwds = Self.claudeFolders(connection.update?.board ?? [])
        if todayRead == nil { phase = .loading }
        do {
            let report = try await read(connection, cwds: cwds, since: Calendar.current.startOfDay(for: .now))
            today = report.buckets
            todayRead = .now
            phase = .idle
            onChange?()
        } catch {
            phase = .failed(inputErrorMessage(error))
        }
    }

    /// Reads the last `historyDays` days; the first time this takes long.
    func loadHistory() async {
        guard let connection else { return }
        guard connection.config.uploadAllowed else {
            historyPhase = .filesOff
            return
        }
        historyPhase = .loading
        do {
            let report = try await read(
                connection,
                cwds: Self.claudeFolders(connection.update?.board ?? []),
                since: Self.historyStart()
            )
            history = report.buckets
            historyPhase = .idle
        } catch {
            historyPhase = .failed(inputErrorMessage(error))
        }
    }

    /// Start of the first day of the history.
    static func historyStart(now: Date = .now) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
    }

    /// Today's usage of the host, or of one directory; `nil` before it was
    /// read.
    func todaySum(cwd: String? = nil, prices: UsagePrices) -> WidgetSnapshot.Usage? {
        guard todayRead != nil else { return nil }
        let day = Calendar.current.startOfDay(for: .now)
        var usage = Self.sum(today, from: day, folder: cwd.map(Self.projectFolder), prices: prices)
        usage.day = day
        return usage
    }

    /// Claude Code's folder name for a working directory, as in the core
    /// (`claude::project_dir`): directories that share it share their
    /// usage, which the core reports under the first of them.
    static func projectFolder(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Forgets what was read, e.g. when the entry now points at another
    /// machine whose session files have the same names.
    func reset() {
        today = []
        todayRead = nil
        history = nil
        phase = .idle
        historyPhase = .idle
        restored = nil
        if let connection { Self.forget(host: connection.id) }
        onChange?()
    }

    /// The sum of the buckets in `[from, to)`, for `cwd` or all.
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

    private func read(_ connection: HostConnection, cwds: [String], since: Date) async throws -> UsageReport {
        // Without a connection the board is empty; that is no empty usage.
        guard connection.isLive else { throw ConnectionFailure.notConnected }
        await restoreIfNeeded(connection)
        guard !cwds.isEmpty else { return UsageReport(buckets: []) }
        let report = try await connection.usage(cwds: cwds, since: since)
        if let state = await connection.usageState(), let url = Self.fileURL(connection.id) {
            await Task.detached {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(state.utf8).write(to: url, options: .atomic)
            }.value
        }
        return report
    }

    /// A new session starts with nothing read; it gets the kept state first.
    private func restoreIfNeeded(_ connection: HostConnection) async {
        guard restored != connection.generation else { return }
        restored = connection.generation
        guard let url = Self.fileURL(connection.id) else { return }
        let state = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
        if let state { await connection.restoreUsageState(state) }
    }

    /// `nil` in the demo mode, which keeps nothing.
    private static func fileURL(_ host: UUID) -> URL? {
        guard !DemoMode.isOn else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/usage/\(host.uuidString).json")
    }

    /// Drops the kept state of a removed host.
    static func forget(host: UUID) {
        guard let url = fileURL(host) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension UsageBucket {
    var start: Date { Date(timeIntervalSince1970: TimeInterval(hourStartMs) / 1000) }
}
