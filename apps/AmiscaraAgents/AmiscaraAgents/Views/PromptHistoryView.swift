import SwiftUI

/// The prompts sent to one pane, newest first (#229). Picking one hands it
/// to the composer; nothing is sent from here.
struct PromptHistoryView: View {
    let history: PromptHistory
    let key: String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [String] {
        let all = history.prompts(for: key)
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown, id: \.self) { prompt in
                    Button {
                        pick(prompt)
                        dismiss()
                    } label: {
                        Text(prompt)
                            .lineLimit(4)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #if !os(tvOS)
                    .swipeActions {
                        Button("Löschen", systemImage: "trash", role: .destructive) {
                            history.remove(prompt, for: key)
                        }
                    }
                    #endif
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Noch keine Prompts" : "Keine Treffer",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(query.isEmpty ? "Was Sie an diese Pane senden, steht hier." : "")
                    )
                }
            }
            #if !os(tvOS)
            .searchable(text: $query, prompt: "Verlauf durchsuchen")
            #endif
            .navigationTitle("Verlauf")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Verlauf leeren", role: .destructive) {
                        history.clear(key)
                    }
                    .disabled(history.prompts(for: key).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
