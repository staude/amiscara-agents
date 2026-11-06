#if !os(tvOS)
import SwiftUI

/// The repository whose existing worktrees "Worktree öffnen …" offers
/// (#343): any space of it lists them, herdr opens them from the
/// repository's main checkout when that has a space.
struct OpenWorktreeTarget: Identifiable {
    let connection: HostConnection
    let workspace: WorkspaceItem

    var id: String { "\(connection.id.uuidString)/\(workspace.workspaceId)" }

    /// The space to list and open from: the repository's main checkout if
    /// it has a space, else this one.
    @MainActor var source: WorkspaceItem {
        WorktreeSource.repository(of: workspace, in: connection.update?.workspaces ?? []) ?? workspace
    }

    var repositoryName: String {
        workspace.repoName ?? workspace.name
    }

    /// A Git space on a host that takes input.
    @MainActor static func available(for workspace: WorkspaceItem, on connection: HostConnection) -> Bool {
        workspace.repoKey != nil && connection.config.inputAllowed
    }
}

/// The existing worktrees of a repository that no space shows, with a
/// search; tapping one opens it as a space and selects it.
struct OpenWorktreeView: View {
    let target: OpenWorktreeTarget
    let onOpened: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var worktrees: [WorktreeChoice]?
    @State private var query = ""
    @State private var opening: String?
    @State private var error: String?

    private var shown: [WorktreeChoice] {
        (worktrees ?? []).filter {
            worktreeMatches(query, branch: $0.branch, label: $0.label, path: $0.path)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Suchen …", text: $query)
                        .technicalInput()
                }
                Section {
                    if worktrees == nil, error == nil {
                        ProgressView()
                    } else if worktrees?.isEmpty == true {
                        Text("Alle Worktrees dieses Repos sind schon als Space offen.")
                            .foregroundStyle(.secondary)
                    } else if worktrees != nil, shown.isEmpty {
                        Text("Kein Worktree passt zur Suche.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown, id: \.path) { worktree in
                        Button {
                            open(worktree)
                        } label: {
                            row(worktree)
                        }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Worktree öffnen – \(target.repositoryName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(width: 480, height: 420)
        #endif
    }

    private func row(_ worktree: WorktreeChoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.branch ?? String(localized: "(losgelöst) \(worktree.label)"))
                    .lineLimit(1)
                Text(worktree.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if opening == worktree.path {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            worktrees = try await target.connection.listWorktrees(of: target.source.workspaceId)
        } catch {
            self.error = inputErrorMessage(error)
        }
    }

    private func open(_ worktree: WorktreeChoice) {
        opening = worktree.path
        error = nil
        let from = target.source.workspaceId
        Task {
            defer { opening = nil }
            do {
                let created = try await target.connection.openWorktree(from: from, path: worktree.path)
                onOpened(created)
                dismiss()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}
#endif
