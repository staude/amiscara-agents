import SwiftUI

/// A tab or space the user wants to close in herdr. Closing ends what runs
/// in its panes, agents included, so it is always confirmed first.
struct CloseTarget: Identifiable {
    enum Kind {
        /// `worktrees`: linked worktree spaces of a repository's space,
        /// which herdr closes along with it.
        case space(workspaceID: String, worktrees: Int)
        case tab(tabID: String)
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
        }
    }

    var title: String {
        switch kind {
        case .space: String(localized: "Space „\(name)“ schließen?")
        case .tab: String(localized: "Tab „\(name)“ schließen?")
        }
    }

    var message: String {
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
        }
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
        }
    }
}

extension View {
    /// Asks before closing `target` and shows herdr's refusal if there is one.
    func closeConfirmation(_ target: Binding<CloseTarget?>) -> some View {
        modifier(CloseConfirmation(target: target))
    }
}

private struct CloseConfirmation: ViewModifier {
    @Binding var target: CloseTarget?
    @State private var error: String?

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
                            self.error = inputErrorMessage(error)
                        }
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .alert(
                "Schließen fehlgeschlagen",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
                presenting: error
            ) { _ in
                Button("OK") {}
            } message: { error in
                Text(error)
            }
    }
}
