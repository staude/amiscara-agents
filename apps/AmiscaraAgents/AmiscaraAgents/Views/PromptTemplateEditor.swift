import SwiftUI

/// Sheet to add, edit, reorder and delete prompt templates. Changes are
/// saved right away; templates without text are dropped when the sheet closes.
struct PromptTemplateEditor: View {
    @Bindable var store: PromptTemplateStore
    /// Repositories of the connected hosts, offered as scope.
    let repos: [String]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: PromptTemplate.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($store.templates) { $template in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name", text: $template.name)
                                .font(.headline)
                            TextField("Text mit {Platzhaltern}", text: $template.text, axis: .vertical)
                                .lineLimit(2...6)
                                .focused($focused, equals: template.id)
                            HStack {
                                Picker("Repository", selection: $template.repo) {
                                    Text("Alle Repos").tag(String?.none)
                                    ForEach(scopes(including: template.repo), id: \.self) { repo in
                                        Text(repo).tag(String?.some(repo))
                                    }
                                }
                                #if os(macOS)
                                Button {
                                    store.templates.removeAll { $0.id == template.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Löschen")
                                #endif
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { store.templates.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.templates.remove(atOffsets: $0) }
                } footer: {
                    Text("Ein Tipp auf eine Vorlage fragt die Platzhalter ab und setzt den Text in die Eingabe, ohne ihn zu senden. Vorbelegt sind {nr} (Issue-Nummer des Branches), {branch} und {space}.")
                }
                Section {
                    Button("Vorlage hinzufügen", systemImage: "plus") {
                        focused = store.add().id
                    }
                }
                if let message = store.saveError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Vorlagen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .onDisappear { store.removeBlank() }
    }

    /// The repositories to choose from; a saved scope whose host is gone
    /// stays selectable.
    private func scopes(including current: String?) -> [String] {
        var all = Set(repos)
        if let current { all.insert(current) }
        return all.sorted()
    }
}
