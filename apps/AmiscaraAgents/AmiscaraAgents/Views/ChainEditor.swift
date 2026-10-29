import SwiftUI

/// The agent a chain is added to (#300).
struct ChainSource: Identifiable {
    let connection: HostConnection
    let agent: BoardItem

    var id: String { "\(connection.id)/\(agent.paneId)" }
}

/// Adds a chain to an agent (#300): when it finishes or waits, a prompt
/// goes to an agent of the same host, itself included. The chain is kept
/// on the host, so every device shows it.
struct ChainEditor: View {
    let source: ChainSource
    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ChainTrigger.done
    @State private var target: String
    @State private var text = ""
    @State private var repeats = false
    @State private var saving = false
    @State private var error: String?

    init(source: ChainSource) {
        self.source = source
        // Usually another agent goes on; the first other one to start with.
        let other = source.connection.update?.board.first { $0.paneId != source.agent.paneId }
        _target = State(initialValue: other?.paneId ?? source.agent.paneId)
    }

    private var agents: [BoardItem] { source.connection.update?.board ?? [source.agent] }

    private var toItself: Bool { target == source.agent.paneId }

    /// The target prompts this agent every time already; both ways every
    /// time would never end.
    private var loopsBack: Bool {
        agents.first { $0.paneId == target }?.chains.contains {
            $0.repeat && !$0.failed && $0.targetPaneId == source.agent.paneId
        } ?? false
    }

    /// Counted as the core does: Unicode scalars, not what shows as one
    /// character (an emoji with skin tone is two).
    private var characters: Int {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.count
    }

    /// A waiting agent refuses prompts, so it cannot be its own target.
    private var targets: [BoardItem] {
        trigger == .blocked ? agents.filter { $0.paneId != source.agent.paneId } : agents
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Wenn \(source.agent.chainName)", selection: $trigger) {
                        Text("fertig ist").tag(ChainTrigger.done)
                        Text("wartet").tag(ChainTrigger.blocked)
                    }
                    Picker("Senden an", selection: $target) {
                        ForEach(targets, id: \.paneId) { agent in
                            Text(agent.paneId == source.agent.paneId
                                ? String(localized: "\(agent.chainName) (selbst)")
                                : agent.chainName)
                                .tag(agent.paneId)
                        }
                    }
                }
                Section {
                    TextField("Prompt", text: $text, prompt: Text("z. B. /issue-approve 300"))
                        .technicalInput()
                        .onSubmit(save)
                    HStack {
                        let replies = QuickReplyStore.shared.usable
                        if !replies.isEmpty {
                            Menu("Schnellantwort") {
                                ForEach(replies) { reply in
                                    Button(reply.trimmed) { text = reply.trimmed }
                                }
                            }
                            .fixedSize()
                        }
                        Spacer()
                        Text(verbatim: "\(characters)/160")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(characters > 160 ? .red : .secondary)
                    }
                }
                Section {
                    Toggle("Jedes Mal senden", isOn: $repeats)
                        .disabled(toItself || loopsBack)
                } footer: {
                    if toItself {
                        Text("An sich selbst nur einmal: Jedes Mal hielte den Agent für immer beschäftigt.")
                    } else if loopsBack {
                        Text("Das Ziel sendet schon jedes Mal hierher; jedes Mal in beide Richtungen liefe ohne Ende.")
                    } else {
                        Text("Sonst nur beim nächsten Mal; danach ist die Kette weg.")
                    }
                }
                Section {
                    if let error {
                        Text(error).foregroundStyle(.red).selectableText()
                    }
                } footer: {
                    Text("Die Kette liegt auf dem Host. Senden tut ein Gerät, das gerade verbunden ist; ein iPhone im Hintergrund nicht.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Kette anlegen")
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
            .onChange(of: target) {
                if toItself || loopsBack { repeats = false }
            }
            .onChange(of: trigger) {
                if trigger == .blocked, toItself, let other = targets.first {
                    target = other.paneId
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 440)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var canSave: Bool {
        !saving && (1 ... 160).contains(characters) && !(trigger == .blocked && toItself)
    }

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        let (trigger, repeats, target, text) = (trigger, repeats && !toItself && !loopsBack, target, text)
        Task {
            defer { saving = false }
            do {
                try await source.connection.addChain(to: source.agent.paneId, trigger: trigger, repeats: repeats, target: target, text: text)
                dismiss()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}

/// The chains of a host and this device's log of them, for its dashboard
/// (#300).
struct ChainsSection: View {
    let connection: HostConnection
    @State private var error: String?

    var body: some View {
        let agents = connection.update?.board ?? []
        let chained = agents.filter { !$0.chains.isEmpty }
        let log = ChainLog.shared.entries(host: connection.id)
        if !chained.isEmpty || !log.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ketten")
                    .font(.headline)
                ForEach(chained, id: \.paneId) { agent in
                    ForEach(agent.chains, id: \.id) { chain in
                        row(agent, chain)
                    }
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !log.isEmpty {
                    DisclosureGroup("Protokoll") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                                logRow(entry)
                            }
                            Button("Protokoll leeren") { ChainLog.shared.clear(host: connection.id) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func row(_ agent: BoardItem, _ chain: ChainItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chain.trigger == .done
                    ? String(localized: "\(agent.chainName) fertig → \(chain.targetName)")
                    : String(localized: "\(agent.chainName) wartet → \(chain.targetName)"))
                    .lineLimit(1)
                Text(chain.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if chain.failed {
                    Text("Fehlgeschlagen, läuft nicht mehr")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if chain.repeat {
                    Text("Jedes Mal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Einmal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if connection.config.inputAllowed && connection.isLive {
                Button("Kette löschen", systemImage: "trash", role: .destructive) {
                    remove(chain, of: agent)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func logRow(_ entry: ChainLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(entry.outcome.label)
                    .foregroundStyle(entry.outcome == .sent ? Color.secondary : entry.outcome == .failed ? .red : .orange)
                Text(verbatim: "\(entry.trigger) → \(entry.target)")
                    .lineLimit(1)
                Spacer()
                Text(entry.at, style: .relative)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            Text(entry.reason.map { "\(entry.text) · \($0)" } ?? entry.text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func remove(_ chain: ChainItem, of agent: BoardItem) {
        error = nil
        Task {
            do {
                try await connection.removeChain(chain.id, from: agent.paneId)
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}

extension ChainLog.Entry.Outcome {
    var label: String {
        switch self {
        case .sent: String(localized: "gesendet")
        case .failed: String(localized: "fehlgeschlagen")
        case .skipped: String(localized: "übersprungen")
        }
    }
}

extension BoardItem {
    /// An agent in a chain: its name, else its kind and space.
    var chainName: String {
        name ?? "\(agent) · \(workspaceName)"
    }
}

extension ChainItem {
    /// The target as the sidebar row names it; a gone pane shows as such.
    var targetName: String {
        targetLabel.isEmpty ? String(localized: "geschlossenes Pane") : targetLabel
    }
}
