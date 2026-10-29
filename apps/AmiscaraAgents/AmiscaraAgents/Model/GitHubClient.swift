#if !os(tvOS)
import Foundation

/// Talks to GitHub for the pull requests of a host's spaces (#309), with the
/// host's token from `GitHubToken`: the open pull requests of a
/// repository, one in detail, its diff, and merging it. Reading goes
/// through GraphQL, the diff and the merge through REST.
struct GitHubClient {
    let token: String

    private static let api = URL(string: "https://api.github.com")!
    /// Diffs are read up to this size, then cut at a line end.
    static let maxDiffBytes = 4 * 1024 * 1024

    /// The open pull requests of `owner/name` and the merge methods it allows.
    func pullRequests(owner: String, name: String) async throws -> RepoPullRequests {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
            pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft headRefName headRefOid
                headRepositoryOwner { login }
                reviewDecision mergeable mergeStateStatus
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
        }
        """
        let data: ListData = try await graphQL(query, ["owner": owner, "name": name])
        guard let repository = data.repository else { throw GitHubError.noAccess }
        return RepoPullRequests(
            methods: MergeMethods(
                squash: repository.squashMergeAllowed,
                merge: repository.mergeCommitAllowed,
                rebase: repository.rebaseMergeAllowed
            ),
            pullRequests: repository.pullRequests.nodes.map { node in
                PullRequestSummary(
                    owner: owner,
                    repoName: name,
                    number: node.number,
                    title: node.title,
                    url: node.url,
                    isDraft: node.isDraft,
                    headRefName: node.headRefName,
                    headOwner: node.headRepositoryOwner?.login,
                    headOid: node.headRefOid,
                    review: node.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
                    checks: node.commits.nodes.first?.commit.statusCheckRollup.map { CheckState(rollup: $0.state) },
                    mergeable: node.mergeable,
                    mergeState: node.mergeStateStatus
                )
            }
        )
    }

    /// Description, comments, reviews and checks of a pull request.
    func detail(_ pr: PullRequestSummary) async throws -> PullRequestDetail {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              title body isDraft headRefOid baseRefName createdAt
              author { login }
              reviewDecision mergeable mergeStateStatus
              comments(first: 100) { nodes { author { login } body createdAt url } }
              reviews(first: 50) { nodes { author { login } state body submittedAt url comments { totalCount } } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
                __typename
                ... on CheckRun { name status conclusion detailsUrl }
                ... on StatusContext { context state targetUrl }
              } } } } } }
            }
          }
        }
        """
        let data: DetailData = try await graphQL(
            query, ["owner": pr.owner, "name": pr.repoName, "number": Int(pr.number)]
        )
        guard let node = data.repository?.pullRequest else { throw GitHubError.noAccess }
        var entries = node.comments.nodes.map { comment in
            PullRequestDetail.Entry(
                author: comment.author?.login, body: comment.body, date: comment.createdAt,
                url: comment.url, review: nil, lineComments: 0
            )
        }
        // A review without text or verdict holds only line comments.
        // A pending review is the token owner's unsent draft.
        entries += node.reviews.nodes.filter { $0.state != "PENDING" }.map { review in
            PullRequestDetail.Entry(
                author: review.author?.login, body: review.body, date: review.submittedAt,
                url: review.url, review: review.state, lineComments: review.comments.totalCount
            )
        }
        entries.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let contexts = node.commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
        return PullRequestDetail(
            title: node.title,
            body: node.body,
            author: node.author?.login,
            createdAt: node.createdAt,
            isDraft: node.isDraft,
            headOid: node.headRefOid,
            baseRefName: node.baseRefName,
            review: node.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            mergeable: node.mergeable,
            mergeState: node.mergeStateStatus,
            checks: contexts.compactMap(\.check),
            entries: entries
        )
    }

    /// The unified diff of a pull request at the head `detail` was read
    /// with, cut at `maxDiffBytes`: the same as GitHub's for the pull
    /// request, from the merge base, so the diff shown is the one merged.
    func diff(_ pr: PullRequestSummary, at detail: PullRequestDetail) async throws -> (text: String, truncated: Bool) {
        var request = request(path: "/repos/\(pr.owner)/\(pr.repoName)/compare/\(detail.baseRefName)...\(detail.headOid)")
        request.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 406 {
            throw GitHubError.diffTooLarge(pr.url)
        }
        try check(data, response)
        var bytes = data
        let truncated = bytes.count > Self.maxDiffBytes
        if truncated {
            bytes = bytes.prefix(Self.maxDiffBytes)
            if let end = bytes.lastIndex(of: UInt8(ascii: "\n")) {
                bytes = bytes.prefix(through: end)
            }
        }
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }

    /// Merges a pull request with `method`, only while its head is still
    /// `sha`; GitHub refuses it when a commit came in since.
    func merge(_ pr: PullRequestSummary, method: MergeMethod, sha: String) async throws {
        var request = request(path: "/repos/\(pr.owner)/\(pr.repoName)/pulls/\(pr.number)/merge")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["merge_method": method.rawValue, "sha": sha])
        let (data, response) = try await URLSession.shared.data(for: request)
        // Here 403 mostly means a missing write permission; GitHub says which.
        try check(data, response, forbiddenSaysWhy: true)
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: Self.api.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func graphQL<T: Decodable>(_ query: String, _ variables: [String: Any]) async throws -> T {
        var request = request(path: "/graphql")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(GraphQLResponse<T>.self, from: data)
        // A field the token may not read (e.g. checks without "Checks")
        // comes back empty with the rest; only the repository missing means
        // no access, and that decodes as `nil` repository.
        if let data = result.data, result.errors?.allSatisfy({ $0.type == "FORBIDDEN" }) ?? true {
            return data
        }
        if let error = result.errors?.first {
            // A repository the token cannot see is "not found".
            if error.type == "NOT_FOUND" || error.type == "FORBIDDEN" { throw GitHubError.noAccess }
            throw GitHubError.message(error.message)
        }
        guard let data = result.data else { throw GitHubError.message(String(localized: "Leere Antwort von GitHub.")) }
        return data
    }

    private func check(_ data: Data, _ response: URLResponse, forbiddenSaysWhy: Bool = false) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else { return }
        switch status {
        case 401: throw GitHubError.tokenInvalid
        case 403 where (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw GitHubError.message(String(localized: "GitHub begrenzt gerade die Anfragen dieses Tokens. Später noch einmal versuchen."))
        case 403 where forbiddenSaysWhy:
            let message = (try? JSONDecoder().decode(RESTError.self, from: data))?.message
            throw message.map(GitHubError.message) ?? GitHubError.noAccess
        case 403, 404: throw GitHubError.noAccess
        default:
            let message = (try? JSONDecoder().decode(RESTError.self, from: data))?.message
            throw GitHubError.message(message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

enum GitHubError: LocalizedError {
    case tokenInvalid
    case noAccess
    case diffTooLarge(URL)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .tokenInvalid:
            String(localized: "GitHub lehnt den Token ab. Einen neuen Token in den Host-Einstellungen eintragen.")
        case .noAccess:
            String(localized: "Der Token hat keinen Zugriff auf dieses Repository.")
        case .diffTooLarge:
            String(localized: "Der Diff ist zu groß für GitHubs Schnittstelle. Auf GitHub ansehen.")
        case .message(let message):
            message
        }
    }
}

/// GitHub's `reviewDecision`.
enum ReviewDecision: String, Hashable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

struct RepoPullRequests {
    let methods: MergeMethods
    let pullRequests: [PullRequestSummary]
}

/// An open pull request as the sidebar shows it.
struct PullRequestSummary: Identifiable, Hashable {
    let owner: String
    let repoName: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let headRefName: String
    /// The owner of the head repository; a fork's has another owner.
    let headOwner: String?
    let headOid: String
    let review: ReviewDecision?
    /// `nil` when the head commit has no checks.
    let checks: CheckState?
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    let mergeable: String
    /// E.g. `CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`.
    let mergeState: String

    var id: String { "\(owner)/\(repoName)#\(number)" }
}

struct PullRequestDetail {
    struct Check {
        let name: String
        let state: CheckState
        let url: URL?
    }

    /// A comment or a review.
    struct Entry: Identifiable {
        let author: String?
        let body: String
        let date: Date?
        let url: URL?
        /// The review's state, e.g. `APPROVED`; `nil` for a comment.
        let review: String?
        let lineComments: Int
        var id: String { url?.absoluteString ?? "\(author ?? "")-\(date?.timeIntervalSince1970 ?? 0)-\(body.hashValue)" }
    }

    let title: String
    let body: String
    let author: String?
    let createdAt: Date?
    let isDraft: Bool
    let headOid: String
    let baseRefName: String
    let review: ReviewDecision?
    let mergeable: String
    let mergeState: String
    let checks: [Check]
    let entries: [Entry]
}

// MARK: - Wire format

private struct GraphQLResponse<T: Decodable>: Decodable {
    struct Failure: Decodable {
        let type: String?
        let message: String
    }

    let data: T?
    let errors: [Failure]?
}

private struct RESTError: Decodable {
    let message: String
}

private struct Login: Decodable {
    let login: String
}

private struct Nodes<T: Decodable>: Decodable {
    let nodes: [T]
}

private struct ListData: Decodable {
    struct Repository: Decodable {
        let squashMergeAllowed: Bool
        let mergeCommitAllowed: Bool
        let rebaseMergeAllowed: Bool
        let pullRequests: Nodes<PullRequest>
    }

    struct PullRequest: Decodable {
        struct Commit: Decodable {
            struct Inner: Decodable {
                struct Rollup: Decodable {
                    let state: String
                }

                let statusCheckRollup: Rollup?
            }

            let commit: Inner
        }

        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let headRefName: String
        let headRefOid: String
        let headRepositoryOwner: Login?
        let reviewDecision: String?
        let mergeable: String
        let mergeStateStatus: String
        let commits: Nodes<Commit>
    }

    let repository: Repository?
}

private struct DetailData: Decodable {
    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    struct PullRequest: Decodable {
        struct Comment: Decodable {
            let author: Login?
            let body: String
            let createdAt: Date?
            let url: URL?
        }

        struct Review: Decodable {
            struct Count: Decodable {
                let totalCount: Int
            }

            let author: Login?
            let state: String
            let body: String
            let submittedAt: Date?
            let url: URL?
            let comments: Count
        }

        struct Commit: Decodable {
            struct Inner: Decodable {
                struct Rollup: Decodable {
                    let state: String
                    let contexts: Nodes<Context>
                }

                let statusCheckRollup: Rollup?
            }

            let commit: Inner
        }

        let title: String
        let body: String
        let isDraft: Bool
        let headRefOid: String
        let baseRefName: String
        let createdAt: Date?
        let author: Login?
        let reviewDecision: String?
        let mergeable: String
        let mergeStateStatus: String
        let comments: Nodes<Comment>
        let reviews: Nodes<Review>
        let commits: Nodes<Commit>
    }

    let repository: Repository?
}

/// A `CheckRun` or a `StatusContext` of the rollup.
private struct Context: Decodable {
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: URL?
    let context: String?
    let state: String?
    let targetUrl: URL?

    var check: PullRequestDetail.Check? {
        if let name {
            return .init(name: name, state: CheckState(status: status, conclusion: conclusion), url: detailsUrl)
        }
        if let context, let state {
            return .init(name: context, state: CheckState(rollup: state), url: targetUrl)
        }
        return nil
    }
}
#endif
