import SwiftUI

/// Input under the pane screen: one-tap answers while an agent waits, a key
/// bar, and a composer. Answers appear only here, next to the screen they
/// answer, never blind from the board.
struct InputBar: View {
    let connection: HostConnection
    let pane: PaneItem

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var composerFocused: Bool

    private var isAgent: Bool { pane.agent != nil }
    private var isBlocked: Bool { isAgent && pane.agentState == .blocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBlocked {
                answerRow
            }
            keyRow
            composer
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .disabled(sending || !connection.isLive)
        .onChange(of: pane.paneId) {
            text = ""
            error = nil
        }
    }

    private var answerRow: some View {
        HStack(spacing: 6) {
            Label("Wartet auf Antwort", systemImage: "hand.raised.fill")
                .foregroundStyle(AgentState.blocked.color)
                .font(.callout.weight(.medium))
            Spacer()
            ForEach(["1", "2", "3"], id: \.self) { key in
                Button(key) { send(keys: [key]) }
                    .help("Option \(key) wählen")
            }
            Button("Bestätigen", systemImage: "return") { send(keys: ["enter"]) }
                .buttonStyle(.borderedProminent)
                .tint(AgentState.blocked.color)
            Button("Abbrechen") { send(keys: ["esc"]) }
        }
        .controlSize(.large)
    }

    private var keyRow: some View {
        HStack(spacing: 4) {
            key("Esc", "esc")
            key("Tab", "tab")
            key("⌃C", "ctrl+c", help: "Control-C")
            Divider().frame(height: 16)
            key("↑", "up")
            key("↓", "down")
            key("←", "left")
            key("→", "right")
            key("↩", "enter", help: "Enter")
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func key(_ label: String, _ name: String, help: String? = nil) -> some View {
        Button(label) { send(keys: [name]) }
            .help(help ?? label)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                isAgent ? "Prompt an \(pane.agent ?? "Agent")" : "Befehl",
                text: $text,
                axis: .vertical
            )
            .lineLimit(1...8)
            .textFieldStyle(.roundedBorder)
            .focused($composerFocused)
            .onSubmit(submit)
            Button(isAgent ? "Senden" : "Ausführen", systemImage: "paperplane.fill", action: submit)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func submit() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        perform {
            try await connection.submit(prompt, to: pane.paneId, isAgent: isAgent)
            text = ""
        }
    }

    private func send(keys: [String]) {
        perform { try await connection.send(keys: keys, to: pane.paneId) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        sending = true
        error = nil
        Task {
            defer {
                sending = false
                composerFocused = true
            }
            do {
                try await action()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}
