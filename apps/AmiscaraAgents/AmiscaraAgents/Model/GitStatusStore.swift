#if !os(tvOS)
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Ahead/behind and uncommitted changes of a host's Git spaces (#343), read
/// by one script on the host for all of them (`HostConnection.worktreeStatus`).
/// Only with input and file access, which the script's tab and its output
/// need; otherwise empty and no runs. Read again when spaces or branches
/// change, the host comes back, an agent in a Git space stops working, the
/// app comes to the front, and every five minutes while the host is live
/// and the app in front; reasons close together make one follow-up
/// (`GitStatusPacing`). A failed run keeps the last values; offline the
/// rows show none.
@MainActor
@Observable
final class GitStatusStore {
    /// By workspace ID.
    private(set) var byWorkspace: [String: SpaceGitStatus] = [:]
    @ObservationIgnored weak var connection: HostConnection?
    @ObservationIgnored private var spaces: [GitSpace] = []
    @ObservationIgnored private var working: Set<String> = []
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var pacing = GitStatusPacing()
    @ObservationIgnored private var followUp: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let interval: Duration = .seconds(300)

    #if os(macOS)
    init() {
        // The scene stays active while another app is in front on the Mac,
        // so coming back is the app's activation.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cameToFront() }
        }
    }
    #endif

    func status(for workspaceID: String) -> SpaceGitStatus? {
        byWorkspace[workspaceID]
    }

    /// The status runs on its own without a tab (#359): herdr-core of the
    /// host answers and input and file access are on. Then the button
    /// "Änderungen" shows only for spaces with changes.
    var automatic: Bool {
        allowed && connection?.update?.herdrCore == true
    }

    /// A space was opened: read again on a host where that opens no tab
    /// (#359), paced like any other reason.
    func spaceOpened() {
        guard automatic else { return }
        request()
    }

    /// The changes of a space were loaded with `count` files: the number
    /// of the view counts until the next run.
    func changesLoaded(workspaceID: String, count: Int) {
        guard var status = byWorkspace[workspaceID] else { return }
        status.changes = UInt32(clamping: count)
        byWorkspace[workspaceID] = status
    }

    /// After a session update.
    func updated(_ update: SessionUpdate, live: Bool) {
        let current = update.workspaces.compactMap { space -> GitSpace? in
            // A space of herdr desktop has no repository key, only a branch
            // when its terminal is in a checkout (#359).
            if let key = space.repoKey {
                return GitSpace(workspaceID: space.workspaceId, repoKey: key, branch: space.branch ?? "")
            }
            guard space.workspaceId.hasPrefix("hc:"), let branch = space.branch else { return nil }
            return GitSpace(workspaceID: space.workspaceId, repoKey: "", branch: branch)
        }
        let nowWorking = Set(update.workspaces.filter { $0.agentState == .working }.map(\.workspaceId))
        let occasion = gitStatusOccasion(
            before: spaces, after: current, wasLive: wasLive, isLive: live,
            workingBefore: working, workingAfter: nowWorking
        )
        spaces = current
        working = nowWorking
        wasLive = live
        // Offline the last values would look current; read again once back.
        if !live, !byWorkspace.isEmpty { byWorkspace = [:] }
        if occasion { request() }
    }

    /// The app came to the front.
    func cameToFront() {
        request()
    }

    /// A reason to read the status: now, or as the one follow-up.
    func request() {
        guard allowed else {
            byWorkspace = [:]
            pacing.reset()
            followUp?.cancel()
            followUp = nil
            return
        }
        guard connection?.isLive == true, !spaces.isEmpty else { return }
        switch pacing.occasion(at: .now) {
        case .now:
            run()
        case .at(let date):
            followUp = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled else { return }
                self.followUp = nil
                if self.pacing.followUpDue() { self.run() }
            }
        case .waiting:
            break
        }
        scheduleTimer()
    }

    private var allowed: Bool {
        guard !DemoMode.isOn, let config = connection?.config else { return false }
        return config.inputAllowed && config.uploadAllowed
    }

    private func run() {
        pacing.started(at: .now)
        Task {
            await load()
            if pacing.finished() { run() }
        }
    }

    private func load() async {
        guard let connection, connection.isLive else { return }
        guard let found = try? await connection.worktreeStatus(), connection.isLive else { return }
        byWorkspace = Dictionary(found.map { ($0.workspaceId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The app is in front; the Mac's app lock does not track that.
    private static var inFront: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        AppLock.shared.isActive
        #endif
    }

    private func scheduleTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                if self.connection?.isLive == true, Self.inFront {
                    self.request()
                }
            }
        }
    }
}
#endif
