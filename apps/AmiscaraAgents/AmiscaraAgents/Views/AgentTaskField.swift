import SwiftUI

/// The first prompt for an agent that is about to start (#344), typed or
/// taken from the prompt templates. The app sends it once herdr reports the
/// agent ready. A section of a form; not on the Apple TV, which has no
/// templates and no keyboard worth the name.
struct AgentTaskField: View {
    @Binding var task: String
    /// Without an agent there is nobody to send the task to.
    let enabled: Bool
    /// Folder name of the repository, to offer its templates.
    let repo: String?
    /// Values for the placeholders of a template, known from the space.
    let prefills: () -> [String: String]
    private let templates = PromptTemplateStore.shared
    @State private var filling: PromptTemplate?

    var body: some View {
        Section {
            TextField("Aufgabe", text: $task, axis: .vertical)
                .lineLimit(3...8)
                .disabled(!enabled)
            let available = templates.matching(repo: repo)
            if !available.isEmpty {
                Menu("Vorlage", systemImage: "text.badge.plus") {
                    ForEach(available) { template in
                        Button(template.title) { use(template) }
                    }
                }
                .disabled(!enabled)
            }
        } header: {
            Text("Aufgabe")
        } footer: {
            Text(enabled
                 ? "Die App sendet die Aufgabe, sobald der Agent bereit ist."
                 : "Nur mit Agent.")
        }
        .sheet(item: $filling) { template in
            PromptTemplateForm(template: template, prefills: prefills()) { insert($0) }
        }
    }

    private func use(_ template: PromptTemplate) {
        if PromptPlaceholders.names(in: template.text).isEmpty {
            insert(template.trimmedText)
        } else {
            filling = template
        }
    }

    /// Replaces an empty field, otherwise follows what is there.
    private func insert(_ text: String) {
        let current = task.trimmingCharacters(in: .whitespacesAndNewlines)
        task = current.isEmpty ? text : current + " " + text
    }
}

/// The space a "new tab with task" sheet is for.
struct NewAgentTabTarget: Identifiable {
    let connection: HostConnection
    let workspace: WorkspaceItem

    var id: String { "\(connection.id.uuidString)/\(workspace.workspaceId)" }
}

/// "New tab with task": a tab in the space with an agent and its first
/// prompt, started in this order so the agent is ready for the prompt.
struct NewAgentTabView: View {
    let connection: HostConnection
    let workspace: WorkspaceItem
    /// Called with the new tab as soon as it exists, so it is shown while
    /// the agent comes up.
    let onCreated: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTabAgentKind") private var agentKind: String?
    @State private var kinds: [String] = []
    @State private var task = ""
    @State private var starting = false
    /// Set when the tab exists but the agent did not start or got no task.
    @State private var createdTab = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                AgentPicker(connection: connection, kind: $agentKind)
                AgentTaskField(task: $task, enabled: agentKind != nil, repo: workspace.repoName) {
                    PromptPlaceholders.prefills(branch: workspace.branch, space: workspace.name)
                }
                if starting {
                    ProgressView {
                        Text("Warte, bis der Agent bereit ist …")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Neuer Tab mit Aufgabe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdTab ? "Schließen" : "Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Starten") { start() }
                        .disabled(starting || createdTab || agentKind == nil)
                }
            }
            .task {
                kinds = await connection.agentKinds()
                if agentKind == nil { agentKind = kinds.first }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 380)
        #endif
    }

    private func start() {
        guard let kind = agentKind else { return }
        starting = true
        error = nil
        Task {
            defer { starting = false }
            let created: Created
            do {
                created = try await connection.createTab(in: workspace.workspaceId)
            } catch {
                self.error = inputErrorMessage(error)
                return
            }
            onCreated(created)
            do {
                _ = try await connection.startAgent(kind: kind, in: created.paneId, task: task)
            } catch {
                // The tab exists; "Starten" again would make a second one.
                createdTab = true
                self.error = agentStartErrorMessage(error)
                return
            }
            dismiss()
        }
    }
}
