import SwiftUI

/// Something the user can rename in herdr: a space, a tab or an agent.
struct RenameTarget: Identifiable {
    enum Kind {
        case space(workspaceID: String)
        case tab(tabID: String)
        case agent(paneID: String)
    }

    let connection: HostConnection
    let kind: Kind
    /// The name shown now, as the starting text.
    let current: String

    var id: String {
        switch kind {
        case .space(let id): "\(connection.id)/space/\(id)"
        case .tab(let id): "\(connection.id)/tab/\(id)"
        case .agent(let id): "\(connection.id)/agent/\(id)"
        }
    }

    var title: String {
        switch kind {
        case .space: String(localized: "Space umbenennen")
        case .tab: String(localized: "Tab umbenennen")
        case .agent: String(localized: "Agent benennen")
        }
    }

    var isAgent: Bool {
        if case .agent = kind { return true }
        return false
    }

    var isSpace: Bool {
        if case .space = kind { return true }
        return false
    }

    /// Only with input allowed and a live connection, like every write.
    @MainActor static func available(on connection: HostConnection) -> Bool {
        connection.config.inputAllowed && connection.isLive
    }
}

/// A small sheet with one text field. A sheet rather than an alert so that
/// herdr's refusal (e.g. an agent name with capitals) can be shown in place.
struct RenameView: View {
    let target: RenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var error: String?

    init(target: RenameTarget) {
        self.target = target
        _name = State(initialValue: target.current)
    }

    var body: some View {
        NavigationStack {
            Form {
                if target.isAgent {
                    TextField("Name", text: $name, prompt: Text("z. B. reviewer"))
                        .technicalInput()
                        .onSubmit(save)
                    Text("Kleinbuchstaben, Ziffern, - und _, höchstens 32 Zeichen. Leer lassen entfernt den Namen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: $name)
                        .onSubmit(save)
                    if target.isSpace {
                        Text(SpaceNames.groupHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(target.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(width: 400, height: target.isAgent || target.isSpace ? 220 : 160)
        #else
        .presentationDetents([.medium])
        #endif
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // An agent may lose its name; spaces and tabs need one.
        return !saving && (target.isAgent || !trimmed.isEmpty)
    }

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                switch target.kind {
                case .space(let id): try await target.connection.renameSpace(id, to: name)
                case .tab(let id): try await target.connection.renameTab(id, to: name)
                case .agent(let id): try await target.connection.renameAgent(in: id, to: name)
                }
                dismiss()
            } catch {
                self.error = message(for: error)
            }
        }
    }

    /// herdr's refusals of an agent name in the app's language.
    private func message(for error: Error) -> String {
        if case FfiError.Rejected(let text) = error {
            if text.contains("(invalid_agent_name)") {
                return String(localized: "Nur Kleinbuchstaben, Ziffern, - und _ sind erlaubt, am Anfang ein Buchstabe.")
            }
            if text.contains("(agent_name_taken)") {
                return String(localized: "Diesen Namen trägt schon ein anderer Agent.")
            }
        }
        return inputErrorMessage(error)
    }
}
