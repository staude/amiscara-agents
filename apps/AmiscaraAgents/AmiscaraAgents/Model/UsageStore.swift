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
    /// The last `UsageSums.historyDays` days; `nil` until the detail page asked.
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
    /// Counts `reset()`s; a run that started before one drops its result.
    @ObservationIgnored private var epoch = 0
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
        let started = epoch
        do {
            let report = try await read(connection, cwds: cwds, since: Calendar.current.startOfDay(for: .now))
            guard epoch == started else { return }
            today = report.buckets
            todayRead = .now
            phase = .idle
            onChange?()
        } catch {
            guard epoch == started else { return }
            phase = .failed(inputErrorMessage(error))
        }
    }

    /// Reads the last `UsageSums.historyDays` days; the first time this takes long.
    func loadHistory() async {
        guard let connection else { return }
        guard connection.config.uploadAllowed else {
            historyPhase = .filesOff
            return
        }
        historyPhase = .loading
        let started = epoch
        do {
            let report = try await read(
                connection,
                cwds: Self.claudeFolders(connection.update?.board ?? []),
                since: UsageSums.historyStart()
            )
            guard epoch == started else { return }
            history = report.buckets
            historyPhase = .idle
        } catch {
            guard epoch == started else { return }
            historyPhase = .failed(inputErrorMessage(error))
        }
    }

    /// Today's usage of the host, or of one directory; `nil` before it was
    /// read.
    func todaySum(cwd: String? = nil, prices: UsagePrices) -> WidgetSnapshot.Usage? {
        // Read before midnight: today is not known yet.
        guard let todayRead, Calendar.current.isDateInToday(todayRead) else { return nil }
        let day = Calendar.current.startOfDay(for: .now)
        var usage = UsageSums.sum(today, from: day, folder: cwd.map(UsageSums.projectFolder), prices: prices)
        usage.day = day
        return usage
    }

    /// Forgets what was read, e.g. when the entry now points at another
    /// machine whose session files have the same names.
    func reset() {
        epoch += 1
        today = []
        todayRead = nil
        history = nil
        phase = .idle
        historyPhase = .idle
        restored = nil
        if let connection { Self.forget(host: connection.id) }
        onChange?()
    }

    private func read(_ connection: HostConnection, cwds: [String], since: Date) async throws -> UsageReport {
        // Without a connection the board is empty; that is no empty usage.
        guard connection.isLive else { throw ConnectionFailure.notConnected }
        await restoreIfNeeded(connection)
        guard !cwds.isEmpty else { return UsageReport(buckets: []) }
        let generation = connection.generation
        let report: UsageReport
        do {
            report = try await connection.usage(cwds: cwds, since: since)
        } catch {
            // What was read before the error stays read.
            await save(connection, generation: generation)
            throw error
        }
        await save(connection, generation: generation)
        return report
    }

    /// Keeps what the session has read. A session started meanwhile has read
    /// nothing yet; its empty state must not replace the kept one.
    private func save(_ connection: HostConnection, generation: Int) async {
        if connection.generation == generation, let state = await connection.usageState(),
           let url = Self.fileURL(connection.id) {
            await Task.detached {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(state.utf8).write(to: url, options: .atomic)
            }.value
        }
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
