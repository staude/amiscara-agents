import SwiftUI

/// A tab or space the user wants to close in herdr. Closing ends what runs
/// in its panes, agents included, so it is always confirmed first.
struct CloseTarget: Identifiable {
    enum Kind {
        /// `worktrees`: linked worktree spaces of a repository's space,
        /// which herdr closes along with it.
        case space(workspaceID: String, worktrees: Int)
        case tab(tabID: String)
        #if !os(tvOS)
        /// The linked worktree a space shows, removed with its space (#343);
        /// the branch stays. `status` as last read, for the warning.
        case worktree(workspaceID: String, status: SpaceGitStatus?)
        #endif
    }

    let connection: HostConnection
    let kind: Kind
    let name: String
    /// The most urgent agent state inside, to warn about a running agent.
    let agentState: AgentState

    var id: String {
        switch kind {
        case .space(let id, _): "\(connection.id)/space/\(id)"
        case .tab(let id): "\(connection.id)/tab/\(id)"
        #if !os(tvOS)
        case .worktree(let id, _): "\(connection.id)/worktree/\(id)"
        #endif
        }
    }

    var title: String {
        switch kind {
        case .space: String(localized: "Space „\(name)“ schließen?")
        case .tab: String(localized: "Tab „\(name)“ schließen?")
        #if !os(tvOS)
        case .worktree: String(localized: "Worktree „\(name)“ entfernen?")
        #endif
        }
    }

    var message: String {
        #if !os(tvOS)
        if case .worktree(_, let status) = kind { return worktreeMessage(status) }
        #endif
        let state = switch agentState {
        case .working: String(localized: "Darin arbeitet noch ein Agent. Schließen beendet ihn und alles, was in den Panes läuft.")
        case .blocked: String(localized: "Darin wartet ein Agent auf eine Antwort. Schließen beendet ihn und alles, was in den Panes läuft.")
        default: String(localized: "Schließen beendet alles, was in den Panes läuft.")
        }
        guard case .space(_, let worktrees) = kind, worktrees > 0 else { return state }
        return String(localized: "Die \(worktrees) Worktree-Spaces darunter werden mit geschlossen, die Verzeichnisse bleiben.") + " " + state
    }

    var buttonLabel: String {
        switch kind {
        case .space: String(localized: "Space schließen")
        case .tab: String(localized: "Tab schließen")
        #if !os(tvOS)
        case .worktree: String(localized: "Worktree entfernen")
        #endif
        }
    }

    /// The title of the alert when herdr or the app refused.
    var failureTitle: String {
        #if !os(tvOS)
        if case .worktree = kind { return String(localized: "Entfernen fehlgeschlagen") }
        #endif
        return String(localized: "Schließen fehlgeschlagen")
    }

    /// A space, with its linked worktree spaces when it is a repository's:
    /// the warning then covers the agents in those too.
    @MainActor static func space(_ workspace: WorkspaceItem, on connection: HostConnection) -> CloseTarget {
        let worktrees = workspace.worktreeName == nil && workspace.repoKey != nil
            ? (connection.update?.workspaces ?? []).filter { $0.repoKey == workspace.repoKey && $0.worktreeName != nil }
            : []
        let states = ([workspace] + worktrees).map(\.agentState)
        return CloseTarget(
            connection: connection,
            kind: .space(workspaceID: workspace.workspaceId, worktrees: worktrees.count),
            name: workspace.worktreeName ?? workspace.name,
            agentState: states.contains(.blocked) ? .blocked : states.contains(.working) ? .working : workspace.agentState
        )
    }

    @MainActor func perform() async throws {
        switch kind {
        case .space(let id, let worktrees): try await connection.closeSpace(id, withWorktrees: worktrees > 0)
        case .tab(let id): try await connection.closeTab(id)
        #if !os(tvOS)
        case .worktree(let id, _):
            // Fresh, not the row's: untracked files count too.
            guard let status = try await connection.worktreeStatus(only: id).first else {
                throw WorktreeRemoval.statusUnknown
            }
            guard status.changes == 0 else { throw WorktreeRemoval.uncommitted(status.changes) }
            try await connection.removeWorktree(id)
        #endif
        }
    }
}

#if !os(tvOS)
extension CloseTarget {
    /// A linked worktree on a host with input and file access, which the
    /// check for changes needs.
    @MainActor static func worktreeRemovable(_ workspace: WorkspaceItem, on connection: HostConnection) -> Bool {
        workspace.worktreeName != nil && connection.config.inputAllowed && connection.config.uploadAllowed
    }

    @MainActor static func worktree(_ workspace: WorkspaceItem, on connection: HostConnection) -> CloseTarget {
        CloseTarget(
            connection: connection,
            kind: .worktree(workspaceID: workspace.workspaceId, status: connection.gitStatus.status(for: workspace.workspaceId)),
            name: workspace.branch ?? workspace.worktreeName ?? workspace.name,
            agentState: workspace.agentState
        )
    }

    fileprivate func worktreeMessage(_ status: SpaceGitStatus?) -> String {
        var parts = [String(localized: "Das Verzeichnis wird gelöscht, der Branch bleibt.")]
        switch agentState {
        case .working, .blocked:
            parts.append(String(localized: "Darin läuft noch ein Agent; er wird beendet."))
        default:
            break
        }
        if let status {
            if !status.hasUpstream {
                parts.append(String(localized: "Der Branch ist nicht gepusht."))
            } else if status.ahead > 0 {
                parts.append(String(localized: "\(Int(status.ahead)) Commits sind nicht gepusht."))
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Why the app does not remove a worktree (#343).
enum WorktreeRemoval: LocalizedError {
    case uncommitted(UInt32)
    case statusUnknown

    var errorDescription: String? {
        switch self {
        case .uncommitted(let count):
            String(localized: "Im Worktree sind \(Int(count)) Änderungen nicht committet. Erst committen oder verwerfen.")
        case .statusUnknown:
            String(localized: "Der Git-Status des Worktrees ließ sich nicht lesen. Nichts wurde entfernt.")
        }
    }
}
#endif

extension View {
    /// Asks before closing `target` and shows herdr's refusal if there is one.
    func closeConfirmation(_ target: Binding<CloseTarget?>) -> some View {
        modifier(CloseConfirmation(target: target))
    }
}

private struct CloseConfirmation: ViewModifier {
    @Binding var target: CloseTarget?
    @State private var error: String?
    @State private var errorTitle = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                target?.title ?? "",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                titleVisibility: .visible,
                presenting: target
            ) { target in
                Button(target.buttonLabel, role: .destructive) {
                    Task {
                        do {
                            try await target.perform()
                        } catch {
                            errorTitle = target.failureTitle
                            self.error = inputErrorMessage(error)
                        }
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .alert(
                errorTitle,
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
                presenting: error
            ) { _ in
                Button("OK") {}
            } message: { error in
                Text(error)
            }
    }
}
