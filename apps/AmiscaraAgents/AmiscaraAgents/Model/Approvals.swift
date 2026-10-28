#if !os(tvOS)
import Foundation
import Observation

/// Plans waiting for approval in the GitHub repositories of the hosts
/// (#296): issues with `awaiting-approval` and the overview of their latest
/// plan comment, for hosts with a GitHub token on this device. Answered in
/// the issue's planning tab `plan-<nr>`, never by setting a label: the
/// enon-tools workflow sets `approved` itself. Loaded when a view appears
/// and on refresh, no polling.
@MainActor
@Observable
final class Approvals {
    struct Item: Identifiable, Hashable {
        let hostID: UUID
        let repo: String
        let number: Int
        let title: String
        let url: URL?
        /// `nil` when the issue has no plan comment.
        let overview: String?
        /// The spaces of the repository on the host, to find the tab.
        let workspaceIDs: [String]

        var id: String { "\(hostID.uuidString)|\(repo)#\(number)" }
        /// The same issue on another host has another `id`.
        var issueKey: String { "\(repo)#\(number)" }
        var approveCommand: String { "/issue-approve \(number)" }
    }

    /// What one host gave on the last load.
    struct HostResult {
        var items: [Item] = []
        /// Why nothing could be loaded, e.g. a refused token.
        var error: String?
    }

    enum Answer {
        case approve
        case later
        /// Approve and leave a note for the implementation.
        case note(String)
    }

    enum AnswerFailure: LocalizedError {
        case noTab
        case questionChanged
        case noNotes

        var errorDescription: String? {
            switch self {
            case .noTab:
                String(localized: "Kein wartender Planungs-Tab für dieses Issue.")
            case .questionChanged:
                String(localized: "Der Planungs-Tab stellt gerade eine andere Frage. Im Tab beantworten.")
            case .noNotes:
                String(localized: "Die Frage im Planungs-Tab nimmt keine Notiz an. Im Tab beantworten.")
            }
        }
    }

    private(set) var results: [UUID: HostResult] = [:]
    private(set) var loading = false
    /// Answered from this device, `true` when approved; shown until the
    /// next load no longer lists them.
    private(set) var answered: [String: Bool] = [:]
    /// When each host was last loaded.
    @ObservationIgnored private var loadedAt: [UUID: Date] = [:]

    /// The labels the planning tab offers (enon-tools, `issue-plan` step
    /// 10); with others the app does not answer.
    static let approveLabel = "Ja"
    static let laterLabel = "Später"

    /// The items of one host, or of all hosts with `nil`; an issue in
    /// repositories of several hosts once, preferably where its tab waits.
    func items(for hostID: UUID?, in connections: [HostConnection]) -> [Item] {
        if let hostID { return results[hostID]?.items ?? [] }
        var seen: [String: Int] = [:]
        var items: [Item] = []
        for connection in connections {
            for item in results[connection.id]?.items ?? [] {
                if let index = seen[item.issueKey] {
                    if Self.planTab(for: items[index], in: connections.first { $0.id == items[index].hostID }) == nil,
                       Self.planTab(for: item, in: connection) != nil {
                        items[index] = item
                    }
                } else {
                    seen[item.issueKey] = items.count
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Errors by host name, for one host or all.
    func errors(for hostID: UUID?, in connections: [HostConnection]) -> [(host: String, message: String)] {
        connections
            .filter { hostID == nil || $0.id == hostID }
            .compactMap { connection in
                results[connection.id]?.error.map { (host: connection.config.name, message: $0) }
            }
    }

    /// Loads all hosts with a token; a host loaded less than half a minute
    /// ago is skipped unless `force`. Hosts without a connection keep what
    /// they showed last.
    func load(_ connections: [HostConnection], force: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        for connection in connections {
            if !force, let at = loadedAt[connection.id], Date.now.timeIntervalSince(at) < 30 { continue }
            guard let token = (try? GitHubToken.load(for: connection.id)) ?? nil,
                  !token.isEmpty
            else {
                results[connection.id] = nil
                continue
            }
            guard connection.config.uploadAllowed else {
                results[connection.id] = HostResult(error: ConnectionFailure.approvalsFilesOff.localizedDescription)
                continue
            }
            guard connection.isLive else { continue }
            results[connection.id] = await Self.fetch(connection, token: token)
            loadedAt[connection.id] = .now
        }
        let listed = Set(results.values.flatMap(\.items).map(\.id))
        answered = answered.filter { listed.contains($0.key) }
    }

    /// Forgets a host's items, e.g. after its token changed.
    func reset(_ hostID: UUID) {
        results[hostID] = nil
        loadedAt[hostID] = nil
    }

    /// The agent of the issue's planning tab when it waits for an answer:
    /// `plan-<nr>` in a space of the issue's repository.
    static func planTab(for item: Item, in connection: HostConnection?) -> BoardItem? {
        connection?.update?.board.first { agent in
            agent.name == "plan-\(item.number)"
                && agent.agentState == .blocked
                && item.workspaceIDs.contains(agent.workspaceId)
        }
    }

    /// Whether the tab's question is the approval: its options are exactly
    /// "Ja" and "Später". Read fresh before every answer.
    static func approvalQuestion(in tab: BoardItem, on connection: HostConnection) async -> ChoiceQuestion? {
        guard let question = await connection.choiceQuestion(paneID: tab.paneId),
              Set(question.options.map(\.label)) == [approveLabel, laterLabel],
              question.options.count == 2
        else { return nil }
        return question
    }

    /// Answers the approval question in the issue's planning tab; sends
    /// nothing when the tab asks something else.
    func answer(_ answer: Answer, for item: Item, on connection: HostConnection) async throws {
        guard let tab = Self.planTab(for: item, in: connection) else { throw AnswerFailure.noTab }
        guard let question = await Self.approvalQuestion(in: tab, on: connection),
              let approve = question.options.first(where: { $0.label == Self.approveLabel }),
              let later = question.options.first(where: { $0.label == Self.laterLabel })
        else { throw AnswerFailure.questionChanged }
        switch answer {
        case .approve:
            try await connection.send(keys: [approve.key], to: tab.paneId)
        case .later:
            try await connection.send(keys: [later.key], to: tab.paneId)
        case .note(let text):
            // Claude Code's question with previews takes a note for the
            // focused option: `n` opens the field, Esc leaves it with the
            // note kept, Enter selects the option. Tried against a test
            // session (herdr 0.9.5, Claude Code 2.1.312): Enter inside the
            // field sends the note without an option, so Esc first. The
            // list does not wrap, so enough `up` reach "Ja" as option 1.
            // Without a preview `n` would do nothing and the text would go
            // into the list, so only when the screen offers notes.
            guard question.options.first?.label == Self.approveLabel,
                  let screen = await connection.screenExcerpt(paneID: tab.paneId, lines: 6),
                  screen.contains("n to add notes")
            else { throw AnswerFailure.noNotes }
            let note = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let up = Array(repeating: "up", count: question.options.count + 1)
            try await connection.send(keys: up + ["n"], to: tab.paneId)
            try await connection.send(text: note, to: tab.paneId)
            try await connection.send(keys: ["esc", "enter"], to: tab.paneId)
        }
        if case .later = answer {
            answered[item.id] = false
        } else {
            answered[item.id] = true
        }
    }

    // MARK: - GitHub

    private enum FetchFailure: Error {
        case notFound
        case refused(Int)
        case status(Int)
    }

    private struct Issue: Decodable {
        let number: Int
        let title: String
        let htmlUrl: String
        let pullRequest: PullRequestMark?

        struct PullRequestMark: Decodable {}
    }

    private struct Comment: Decodable {
        let body: String?
    }

    private static func fetch(_ connection: HostConnection, token: String) async -> HostResult {
        let repos: [GitHubRepo]
        do {
            repos = try await connection.githubRepos()
        } catch {
            return HostResult(error: inputErrorMessage(error))
        }
        var result = HostResult()
        scan: for repo in repos {
            do {
                let issues: [Issue] = try await get(
                    "repos/\(repo.repo)/issues?labels=awaiting-approval&state=open&per_page=100",
                    token: token
                ).value
                for issue in issues where issue.pullRequest == nil {
                    let overview = try await latestOverview(repo.repo, issue.number, token: token)
                    result.items.append(Item(
                        hostID: connection.id,
                        repo: repo.repo,
                        number: issue.number,
                        title: issue.title,
                        url: URL(string: issue.htmlUrl),
                        overview: overview,
                        workspaceIDs: repo.workspaceIds
                    ))
                }
            } catch FetchFailure.notFound {
                // Not visible with this token, or no issues.
                continue
            } catch FetchFailure.refused(let status) {
                result.error = status == 401
                    ? String(localized: "GitHub lehnt den Token ab (401). Token in den Host-Einstellungen prüfen.")
                    : String(localized: "GitHub verweigert den Zugriff (403): Rechte des Tokens oder Rate-Limit.")
                break scan
            } catch FetchFailure.status(let status) {
                result.error = String(localized: "GitHub antwortet mit Status \(status).")
                break scan
            } catch {
                result.error = error.localizedDescription
                break scan
            }
        }
        return result
    }

    /// The overview of the issue's latest plan comment, over all pages.
    private static func latestOverview(_ repo: String, _ number: Int, token: String) async throws -> String? {
        var next: URL? = endpoint("repos/\(repo)/issues/\(number)/comments?per_page=100")
        var overview: String?
        while let url = next {
            let (comments, link): ([Comment], URL?) = try await get(url, token: token)
            for comment in comments {
                if let body = comment.body, let found = planOverview(body: body) {
                    overview = found
                }
            }
            next = link
        }
        return overview
    }

    private static func endpoint(_ path: String) -> URL? {
        URL(string: "https://api.github.com/" + path)
    }

    private static func get<T: Decodable>(_ path: String, token: String) async throws -> (value: T, next: URL?) {
        guard let url = endpoint(path) else { throw FetchFailure.notFound }
        return try await get(url, token: token)
    }

    private static func get<T: Decodable>(_ url: URL, token: String) async throws -> (value: T, next: URL?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 404: throw FetchFailure.notFound
        case 401, 403: throw FetchFailure.refused(status)
        default: throw FetchFailure.status(status)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(T.self, from: data)
        let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link")
        return (value, link.flatMap(nextPage))
    }

    /// The `rel="next"` URL of a GitHub `Link` header.
    private static func nextPage(_ header: String) -> URL? {
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"next\"") else { continue }
            return URL(string: String(pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))))
        }
        return nil
    }
}
#endif
