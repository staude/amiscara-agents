import SwiftUI

/// Sheet to add, edit, reorder and delete quick replies. Changes are saved
/// right away; empty entries are dropped when the sheet closes.
struct QuickReplyEditor: View {
    @Bindable var store: QuickReplyStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: QuickReply.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($store.replies) { $reply in
                        HStack {
                            TextField("Text", text: $reply.text, axis: .vertical)
                                .lineLimit(1...4)
                                .focused($focused, equals: reply.id)
                            #if os(macOS) || os(tvOS)
                            // iOS deletes in edit mode; Mac and TV have no such control.
                            Button {
                                store.replies.removeAll { $0.id == reply.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Löschen")
                            #endif
                        }
                    }
                    .onMove { store.replies.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.replies.remove(atOffsets: $0) }
                } footer: {
                    Text("Ein Tipp auf eine Schnellantwort sendet sie sofort. Reihenfolge per Ziehen ändern.")
                }
                Section {
                    Button("Schnellantwort hinzufügen", systemImage: "plus") {
                        focused = store.add().id
                    }
                    Button("Standard wiederherstellen", systemImage: "arrow.counterclockwise") {
                        store.resetToDefaults()
                    }
                }
                if let message = store.saveError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Schnellantworten")
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
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .onDisappear { store.removeBlank() }
    }
}
