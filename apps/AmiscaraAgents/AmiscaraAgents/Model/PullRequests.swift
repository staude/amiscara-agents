#if !os(tvOS)
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The open pull requests of a host's spaces (#309): per space the one whose
/// head is the space's branch in the repository of its `origin` remote, as
/// the approvals (#296) find it.
/// Only with a GitHub token for the host and file access, which reads the
/// Git configuration; otherwise empty and no requests. One request per
/// repository, again when spaces or branches change, every two minutes
/// while the host is live and the app in front, and after a merge.
@MainActor
@Observable
final class PullRequests {
    /// By workspace ID.
    private(set) var byWorkspace: [String: PullRequestSummary] = [:]
    /// What the last refresh found GitHub refusing the token for.
    private(set) var tokenError: String?
    /// The merge methods of each repository, by `owner/name`.
    @ObservationIgnored private var methods: [String: MergeMethods] = [:]
    @ObservationIgnored weak var connection: HostConnection?
    @ObservationIgnored private let hostID: UUID
    @ObservationIgnored private var token: String?
    /// The GitHub repositories of the spaces with their spaces (#296), read
    /// again only in a new session (`generation`) or for other spaces.
    @ObservationIgnored private var repos: [GitHubRepo]?
    @ObservationIgnored private var reposRead: (generation: Int, spaces: [String])?
    @ObservationIgnored private var spaces: [Space] = []
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let interval: Duration = .seconds(120)

    private struct Space: Equatable {
        let workspaceID: String
        let repoKey: String
        let branch: String
    }

    init(host hostID: UUID) {
        self.hostID = hostID
        token = Self.token(for: hostID)
    }

    private static func token(for hostID: UUID) -> String? {
        guard !DemoMode.isOn, let token = (try? GitHubToken.load(for: hostID)) ?? nil, !token.isEmpty else { return nil }
        return token
    }

    var hasToken: Bool { token != nil }

    func pullRequest(for workspaceID: String) -> PullRequestSummary? {
        byWorkspace[workspaceID]
    }

    /// After a session update: refreshes when spaces or branches changed or
    /// the host came back.
    func updated(_ update: SessionUpdate, live: Bool) {
        let current = update.workspaces.compactMap { space -> Space? in
            guard let key = space.repoKey, let branch = space.branch, !branch.isEmpty else { return nil }
            return Space(workspaceID: space.workspaceId, repoKey: key, branch: branch)
        }
        let cameBack = live && !wasLive
        wasLive = live
        guard current != spaces || cameBack else { return }
        spaces = current
        Task { await refresh() }
    }

    /// A new token, or none, from the host settings.
    func tokenChanged() {
        token = Self.token(for: hostID)
        tokenError = nil
        Task { await refresh() }
    }

    /// The method a pull request is merged with: squash, unless its
    /// repository allows only others; `nil` when it allows none.
    func mergeMethod(for pr: PullRequestSummary) -> MergeMethod? {
        guard let allowed = methods["\(pr.owner)/\(pr.repoName)"] else { return .squash }
        return allowed.preferred
    }

    var client: GitHubClient? { token.map(GitHubClient.init(token:)) }

    /// Merges `pr` at `sha` and refreshes at once.
    func merge(_ pr: PullRequestSummary, sha: String) async throws {
        guard let client else { throw GitHubError.tokenInvalid }
        guard let method = mergeMethod(for: pr) else {
            throw GitHubError.message(String(localized: "Das Repository erlaubt keine Merge-Methode."))
        }
        do {
            try await client.merge(pr, method: method, sha: sha)
        } catch GitHubError.tokenInvalid {
            tokenError = GitHubError.tokenInvalid.localizedDescription
            throw GitHubError.tokenInvalid
        }
        byWorkspace = byWorkspace.filter { $0.value.id != pr.id }
        await refresh()
    }

    func refresh() async {
        guard !refreshing else {
            again = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            again = false
            await load()
        } while again
        scheduleTimer()
    }

    private func load() async {
        // Not readable before the first unlock after a restart.
        if token == nil { token = Self.token(for: hostID) }
        guard let connection, let client, connection.config.uploadAllowed else {
            byWorkspace = [:]
            methods = [:]
            return
        }
        guard connection.isLive else { return }
        let spaces = spaces
        // A branch change keeps the repositories; a new space or session
        // reads them again.
        let keys = spaces.map { "\($0.workspaceID) \($0.repoKey)" }
        if reposRead?.generation != connection.generation || reposRead?.spaces != keys,
           let read = try? await connection.githubRepos() {
            repos = read
            reposRead = (connection.generation, keys)
        }
        // Not read yet: keep the last rows.
        guard let repos else { return }
        var found: [String: PullRequestSummary] = [:]
        var allowed: [String: MergeMethods] = [:]
        for repo in repos {
            let parts = repo.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (owner, name) = (parts[0], parts[1])
            let ownSpaces = spaces.filter { repo.workspaceIds.contains($0.workspaceID) }
            guard !ownSpaces.isEmpty else { continue }
            do {
                let result = try await client.pullRequests(owner: owner, name: name)
                allowed[repo.repo] = result.methods
                for space in ownSpaces {
                    found[space.workspaceID] = result.pullRequests.first { pr in
                        pullRequestMatches(
                            headRefName: pr.headRefName, headOwner: pr.headOwner,
                            branch: space.branch, repoOwner: owner
                        )
                    }
                }
            } catch GitHubError.tokenInvalid {
                tokenError = GitHubError.tokenInvalid.localizedDescription
                byWorkspace = [:]
                methods = [:]
                return
            } catch GitHubError.noAccess {
                // No rows for a repository the token cannot see.
            } catch {
                // Offline or GitHub down: keep the last state.
                allowed[repo.repo] = methods[repo.repo]
                for space in ownSpaces {
                    found[space.workspaceID] = byWorkspace[space.workspaceID]
                }
            }
        }
        tokenError = nil
        byWorkspace = found
        methods = allowed
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
        guard timer == nil, token != nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                guard self.token != nil else {
                    self.timer = nil
                    return
                }
                if self.connection?.isLive == true, Self.inFront {
                    await self.refresh()
                }
            }
        }
    }
}
#endif
