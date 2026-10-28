import SwiftUI

#if !os(tvOS)
/// A pull request to show, from the sidebar, the space or the dashboard.
struct PullRequestTarget: Identifiable {
    let connection: HostConnection
    let pullRequest: PullRequestSummary
    var id: String { pullRequest.id }
}

/// The pull request of a space (#309): description, checks, comments and
/// reviews, the diff, and merging it after Face ID or the passcode. Review
/// comments on lines only count here; approving stays on GitHub.
struct PullRequestView: View {
    let connection: HostConnection
    let pullRequest: PullRequestSummary
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PullRequestDetail?
    @State private var files: [DiffFile] = []
    @State private var truncated = false
    @State private var diffLoaded = false
    @State private var diffError: String?
    /// The head the shown diff belongs to; merging needs it to be the
    /// head merged.
    @State private var diffHead: String?
    @State private var error: String?
    @State private var loading = false
    @State private var confirmingMerge = false
    @State private var merging = false
    @State private var mergeError: String?

    private var store: PullRequests { connection.pullRequests }

    var body: some View {
        NavigationStack {
            List {
                header
                // Also after a failed reload, which keeps the last state.
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if let detail {
                    description(detail)
                    if !detail.checks.isEmpty { checks(detail) }
                    if !detail.entries.isEmpty { conversation(detail) }
                }
                diff
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
            .navigationTitle("Pull Request #\(pullRequest.number)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neu laden", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .disabled(loading)
                }
            }
            .confirmationDialog(
                "Pull Request #\(pullRequest.number) mergen?",
                isPresented: $confirmingMerge,
                titleVisibility: .visible
            ) {
                Button("Mergen (\(methodTitle))") { merge() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(pullRequest.title)
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 680)
        #endif
        // Texts and links come from anyone who can comment: only web
        // pages, no links into this or other apps.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .task { await load() }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail?.title ?? pullRequest.title)
                    .font(.headline)
                    .selectableText()
                HStack(spacing: 8) {
                    PullRequestBadge(pullRequest: pullRequest)
                    if detail?.isDraft ?? pullRequest.isDraft {
                        Text("Entwurf")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                    Text(verbatim: "\(pullRequest.owner)/\(pullRequest.repoName) · \(pullRequest.headRefName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let author = detail?.author {
                    Text("von \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Link(destination: pullRequest.url) {
                Label("Auf GitHub öffnen", systemImage: "safari")
            }
            mergeRow
        }
    }

    @ViewBuilder
    private var mergeRow: some View {
        Button {
            confirmingMerge = true
        } label: {
            HStack {
                Label("Mergen …", systemImage: "arrow.triangle.merge")
                if merging {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(mergeBlocked != nil || merging || detail == nil)
        if let mergeBlocked {
            Text(mergeBlocked)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let mergeError {
            Label(mergeError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    /// Why merging is not offered, from the freshest state known.
    private var mergeBlocked: String? {
        if detail?.isDraft ?? pullRequest.isDraft {
            return String(localized: "Ein Entwurf lässt sich nicht mergen. Auf GitHub als fertig markieren.")
        }
        if (detail?.mergeable ?? pullRequest.mergeable) == "CONFLICTING" {
            return String(localized: "Der Pull Request hat Konflikte mit dem Basisbranch.")
        }
        if (detail?.mergeState ?? pullRequest.mergeState) == "BLOCKED" {
            return String(localized: "Blockiert: Es fehlen Reviews oder Checks, die das Repository verlangt.")
        }
        if let detail, diffHead != detail.headOid {
            return String(localized: "Ohne den Diff zum aktuellen Stand lässt sich nicht mergen. Neu laden oder auf GitHub mergen.")
        }
        if store.mergeMethod(for: pullRequest) == nil {
            return String(localized: "Das Repository erlaubt keine Merge-Methode.")
        }
        return nil
    }

    private var methodTitle: String {
        switch store.mergeMethod(for: pullRequest) {
        case .squash, nil: String(localized: "Squash")
        case .merge: String(localized: "Merge-Commit")
        case .rebase: String(localized: "Rebase")
        }
    }

    private func description(_ detail: PullRequestDetail) -> some View {
        Section("Beschreibung") {
            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Keine Beschreibung.")
                    .foregroundStyle(.secondary)
            } else {
                Text(markdown(detail.body))
                    .selectableText()
            }
        }
    }

    private func checks(_ detail: PullRequestDetail) -> some View {
        Section("Checks") {
            // Names repeat, e.g. one job from two workflows.
            ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
                HStack {
                    CheckIcon(state: check.state)
                    Text(check.name)
                        .lineLimit(1)
                    Spacer()
                    if let url = check.url {
                        Link(destination: url) {
                            Label("Details", systemImage: "arrow.up.right.square")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func conversation(_ detail: PullRequestDetail) -> some View {
        Section("Kommentare und Reviews") {
            ForEach(detail.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.author ?? String(localized: "Unbekannt"))
                            .font(.callout.weight(.semibold))
                        if let review = entry.review {
                            ReviewStateLabel(state: review)
                        }
                        Spacer()
                        if let date = entry.date {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !entry.body.isEmpty {
                        Text(markdown(entry.body))
                            .font(.callout)
                            .selectableText()
                    }
                    if entry.lineComments > 0 {
                        Text("Kommentare an Zeilen: \(entry.lineComments), auf GitHub zu lesen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var diff: some View {
        if !diffLoaded {
            Section("Dateien") {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } else if let diffError, files.isEmpty {
            Section("Dateien") {
                Label(diffError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Link("Dateien auf GitHub ansehen", destination: pullRequest.url.appending(path: "files"))
            }
        } else {
            DiffFileList(files: files, truncated: truncated, note: diffError)
        }
    }

    /// Inline Markdown with the line breaks kept; headings and lists stay
    /// as written.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func load() async {
        guard let client = store.client else {
            error = GitHubError.tokenInvalid.localizedDescription
            diffLoaded = true
            return
        }
        loading = true
        defer { loading = false }
        defer { diffLoaded = true }
        let detail: PullRequestDetail
        do {
            detail = try await client.detail(pullRequest)
        } catch {
            self.error = error.localizedDescription
            return
        }
        // The diff of exactly the head merged with, also after a push.
        do {
            let (text, cut) = try await client.diff(pullRequest, at: detail)
            files = await Task.detached { parseDiff(text: text) }.value
            truncated = cut
            diffError = nil
            diffHead = detail.headOid
        } catch {
            files = []
            diffHead = nil
            truncated = false
            diffError = error.localizedDescription
        }
        self.detail = detail
        error = nil
    }

    private func merge() {
        guard let detail else { return }
        mergeError = nil
        merging = true
        Task {
            defer { merging = false }
            let reason = String(localized: "Pull Request #\(pullRequest.number) mergen")
            guard AppLock.isAvailable else {
                mergeError = String(localized: "Mergen verlangt Face ID, Touch ID oder einen Gerätecode. Auf diesem Gerät ist keins eingerichtet.")
                return
            }
            guard await AppLock.shared.confirmOwner(reason: reason) else { return }
            do {
                // The head this view shows; a newer commit makes GitHub refuse.
                try await store.merge(pullRequest, sha: detail.headOid)
                dismiss()
            } catch {
                mergeError = error.localizedDescription
            }
        }
    }
}

/// `#12` with the state of its checks and reviews, as the sidebar shows it.
struct PullRequestBadge: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
            Text(verbatim: "#\(pullRequest.number)")
                .monospacedDigit()
            if let checks = pullRequest.checks {
                CheckIcon(state: checks)
            }
            if let review = pullRequest.review {
                Image(systemName: review.symbol)
                    .foregroundStyle(review.color)
            }
        }
        .font(.caption)
        .foregroundStyle(pullRequest.isDraft ? .tertiary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [String(localized: "Pull Request \(pullRequest.number)")]
        if pullRequest.isDraft { parts.append(String(localized: "Entwurf")) }
        if let checks = pullRequest.checks { parts.append(checks.label) }
        if let review = pullRequest.review { parts.append(review.label) }
        return parts.joined(separator: ", ")
    }
}

private struct CheckIcon: View {
    let state: CheckState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .accessibilityLabel(state.label)
    }
}

private struct ReviewStateLabel: View {
    let state: String

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private var text: String? {
        switch state {
        case "APPROVED": String(localized: "freigegeben")
        case "CHANGES_REQUESTED": String(localized: "Änderungen verlangt")
        case "DISMISSED": String(localized: "verworfen")
        default: nil
        }
    }

    private var color: Color {
        switch state {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .red
        default: .secondary
        }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        }
    }

    var label: String {
        switch self {
        case .success: String(localized: "Checks erfolgreich")
        case .failure: String(localized: "Checks fehlgeschlagen")
        case .pending: String(localized: "Checks laufen")
        }
    }
}

extension ReviewDecision {
    var symbol: String {
        switch self {
        case .approved: "checkmark.seal.fill"
        case .changesRequested: "exclamationmark.bubble.fill"
        case .reviewRequired: "eye"
        }
    }

    var color: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .red
        case .reviewRequired: .secondary
        }
    }

    var label: String {
        switch self {
        case .approved: String(localized: "Review freigegeben")
        case .changesRequested: String(localized: "Änderungen verlangt")
        case .reviewRequired: String(localized: "Review ausstehend")
        }
    }
}
#endif
