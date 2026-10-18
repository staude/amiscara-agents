#if os(tvOS)
import SwiftUI

/// Input under the pane on the Apple TV (#126; extended in #129): answers
/// while an agent waits, a key bar and a prompt field. No attachments and
/// no own dictation: tvOS has no file or photo pickers, and its keyboard
/// (also on the iPhone) dictates by itself.
struct InputBar: View {
    let connection: HostConnection
    let pane: PaneItem

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    private let quickReplies = QuickReplyStore.shared
    @State private var editingQuickReplies = false

    private var isAgent: Bool { pane.agent != nil }
    private var isBlocked: Bool { isAgent && pane.agentState == .blocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isBlocked {
                HStack(spacing: 12) {
                    Label("\(pane.agent ?? "Agent") wartet auf Antwort", systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.orange)
                    Spacer()
                    ForEach(["1", "2", "3"], id: \.self) { key($0, $0) }
                    key("Enter", "enter")
                    key("Esc", "esc")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(quickReplies.replies) { reply in
                        Button(reply.text) { submit(reply.text) }
                    }
                    Button("Schnellantworten bearbeiten", systemImage: "pencil") { editingQuickReplies = true }
                        .labelStyle(.iconOnly)
                    key("Esc", "esc")
                    key("Tab", "tab")
                    key("^C", "ctrl+c")
                    key("↑", "up")
                    key("↓", "down")
                    key("←", "left")
                    key("→", "right")
                    key("↩", "enter")
                }
            }
            .scrollClipDisabled()
            HStack(spacing: 12) {
                TextField(isAgent ? "Prompt an \(pane.agent ?? "Agent")" : "Befehl", text: $text)
                    .onSubmit { submit(text) }
                Button(isAgent ? "Senden" : "Ausführen", systemImage: "paperplane.fill") { submit(text) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .disabled(sending || !connection.isLive)
        .onChange(of: pane.paneId) {
            text = ""
            error = nil
        }
        .sheet(isPresented: $editingQuickReplies) {
            QuickReplyEditor(store: quickReplies)
        }
    }

    private func key(_ label: String, _ name: String) -> some View {
        Button(label) { perform { try await connection.send(keys: [name], to: pane.paneId) } }
    }

    private func submit(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        perform {
            try await connection.submit(prompt, to: pane.paneId, isAgent: isAgent)
            text = ""
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await action()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}
#endif
