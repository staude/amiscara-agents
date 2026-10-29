import SwiftUI

#if !os(tvOS)
/// The composer for several agents at once (#299), under the overview and
/// the host dashboard while agents are picked: text only, without
/// attachments, dictation or live mode. After sending it lists what came of
/// each agent until "Schließen" ends the selection.
struct MultiSendBar: View {
    @Environment(HostStore.self) private var store
    /// The picked agents in list order.
    let targets: [MultiSend.Target]
    /// A send is running; the page keeps the selection mode meanwhile.
    @Binding var sending: Bool
    /// Clears the selection and ends the selection mode.
    let close: () -> Void

    @State private var text = ""
    @State private var sendTask: Task<Void, Never>?
    /// Agents of the running or last send.
    @State private var total = 0
    @State private var results: [MultiSend.Result] = []

    private var canSend: Bool {
        !sending && !targets.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sending || !results.isEmpty {
                resultList
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Prompt an mehrere Agents", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("An \(targets.count) Agenten senden", systemImage: "paperplane.fill", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .padding()
        .background(.bar)
        // Leaving the page stops sending to the agents not reached yet.
        .onDisappear { sendTask?.cancel() }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if sending {
                    ProgressView().controlSize(.small)
                    Text("Sende \(min(results.count + 1, total)) von \(total) …")
                } else {
                    Text("Ergebnis")
                }
                Spacer()
                Button("Schließen") {
                    results = []
                    close()
                }
                .disabled(sending)
            }
            .font(.callout.weight(.medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { result in
                        MultiSendResultRow(result: result)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    private func send() {
        guard canSend else { return }
        let prompt = text
        let targets = targets
        total = targets.count
        results = []
        sending = true
        sendTask = Task {
            let done = await store.sendToMany(prompt, to: targets) { results.append($0) }
            // Text typed meanwhile is kept.
            if done.contains(where: { $0.outcome == .sent }), text == prompt { text = "" }
            sendTask = nil
            sending = false
        }
    }
}

/// What came of one agent: sent, skipped or failed with the reason.
private struct MultiSendResultRow: View {
    let result: MultiSend.Result

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text([result.target.place, result.target.name, result.target.hostName].joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch result.outcome {
        case .sent: "checkmark.circle.fill"
        case .skipped: "arrow.uturn.forward.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch result.outcome {
        case .sent: .green
        case .skipped: .orange
        case .failed: .red
        }
    }

    private var detail: String {
        switch result.outcome {
        case .sent: String(localized: "Gesendet")
        case .skipped(let reason): String(localized: "Übersprungen: \(reason)")
        case .failed(let reason): reason
        }
    }
}

/// A row in the selection mode: a mark before it, dimmed with the reason
/// when the agent cannot be picked.
struct MultiSendRow<Content: View>: View {
    let target: MultiSend.Target
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                content
                if let reason = target.blockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(target.isSelectable ? 1 : 0.5)
        .contentShape(.rect)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
