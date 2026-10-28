import SwiftUI

/// Asks for the placeholders of a template, prefilled where known, and hands
/// back the filled text.
struct PromptTemplateForm: View {
    let template: PromptTemplate
    let prefills: [String: String]
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var names: [String] { PromptPlaceholders.names(in: template.text) }
    private var complete: Bool {
        names.allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var trimmedValues: [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(names, id: \.self) { name in
                        TextField(name, text: binding(name))
                            #if os(iOS)
                            .keyboardType(name == "nr" ? .numberPad : .default)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                }
                Section("Vorschau") {
                    Text(PromptPlaceholders.fill(template.trimmedText, values: trimmedValues))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(template.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("In Eingabe übernehmen") {
                        onInsert(PromptPlaceholders.fill(template.trimmedText, values: trimmedValues))
                        dismiss()
                    }
                    .disabled(!complete)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
        .onAppear { values = prefills.filter { names.contains($0.key) } }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}
