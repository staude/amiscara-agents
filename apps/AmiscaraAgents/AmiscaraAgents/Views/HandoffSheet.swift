#if !os(tvOS)
import SwiftUI

/// Where a handoff (#236) from the clipboard or an
/// `amiscara-agents://prompt` link goes: an agent on a connected host, with
/// a look at the text and the prompt. "Weiter" opens that agent with the
/// text attached as a Markdown file in the composer, the same way as a
/// share (`PendingShare`); the user sends it from there.
struct HandoffSheet: View {
    let request: Handoff.Request

    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = Handoff.prompt
    @State private var selection: String?
    /// Once the user picked, hosts coming up later do not move the choice.
    @State private var picked = false
    @State private var error: String?
    /// The sidebar's order of agents.
    @AppStorage("agentOrder") private var agentOrder = AgentOrder.grouped

    private struct Choice: Identifiable {
        let hostID: UUID
        let hostName: String
        let workspaceID: String
        let paneID: String
        let name: String
        let place: String
        let state: AgentState
        let uploadAllowed: Bool

        var id: String { "\(hostID.uuidString)/\(paneID)" }
    }

    /// Agents on connected hosts that take input, in the sidebar's order.
    private var choices: [Choice] {
        store.connections.filter { $0.isLive && $0.config.inputAllowed }.flatMap { connection -> [Choice] in
            guard let update = connection.update else { return [] }
            return AgentOrder.sorted(update, by: agentOrder).map { entry in
                let agent = entry.agent
                return Choice(
                    hostID: connection.id,
                    hostName: connection.config.name,
                    workspaceID: agent.workspaceId,
                    paneID: agent.paneId,
                    // As in the sidebar: two Claudes in one tab differ by name.
                    name: agent.name.map { "\($0) · \(agent.agent)" } ?? (agent.agent.isEmpty ? String(localized: "Agent") : agent.agent),
                    place: entry.tabNumber.map { "\(agent.spacePlace) · \($0)" } ?? agent.spacePlace,
                    state: agent.agentState,
                    uploadAllowed: connection.config.uploadAllowed
                )
            }
        }
    }

    private var tooLong: Bool { request.text.count > Handoff.maxLength }

    var body: some View {
        let choices = choices
        NavigationStack {
            Form {
                if choices.isEmpty {
                    Text("Kein verbundener Agent. Sobald ein Host verbunden ist, erscheinen seine Agents hier.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: pickedSelection) {
                        ForEach(choices) { choice in
                            HStack(spacing: 8) {
                                StatusDot(state: choice.state)
                                VStack(alignment: .leading) {
                                    Text(choice.name)
                                    Text("\(choice.hostName) · \(choice.place) · \(choice.state.label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(Optional(choice.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Übergabe") {
                    if request.fromLink {
                        Label("Aus einem Link. Prüfen Sie den Text, bevor Sie ihn an einen Agent geben.", systemImage: "link")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ScrollView {
                        Text(previewText)
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .selectableText()
                    }
                    .frame(maxHeight: 220)
                    Group {
                        if request.text.count > Self.previewLength {
                            Text("Die Vorschau zeigt die ersten \(Self.previewLength) von \(request.text.count) Zeichen; die Datei enthält alle.")
                        } else {
                            Text("\(request.text.count) Zeichen")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let choice = choices.first(where: { $0.id == selection }), !choice.uploadAllowed {
                        Text("Hochladen ist für \(choice.hostName) aus; der Text kommt statt einer Datei ins Eingabefeld.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Text("Amiscara Agents öffnet den Agent mit dem Prompt und der Datei im Eingabefeld; gesendet wird erst dort.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if tooLong {
                    Text("Der Text ist zu lang für eine Übergabe.").foregroundStyle(.red)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Übergabe an Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Weiter") { handOver(choices) }
                        .disabled(tooLong || !choices.contains { $0.id == selection })
                }
            }
        }
        // Hosts may still be connecting, e.g. when the link launched the app.
        .onChange(of: choices.map(\.id), initial: true) { _, ids in
            if !picked || !ids.contains(where: { $0 == selection }) {
                selection = preferred(in: choices)
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
    }

    private var pickedSelection: Binding<String?> {
        Binding(
            get: { selection },
            set: {
                selection = $0
                picked = true
            }
        )
    }

    /// The link's agent, else the first on the link's host, else the first.
    /// A pane without a host is looked for on every host.
    private func preferred(in choices: [Choice]) -> String? {
        let onHost = request.host == nil ? choices : choices.filter { request.names(hostID: $0.hostID, name: $0.hostName) }
        let pane = onHost.first { $0.paneID == request.pane }
        return (pane ?? (request.host == nil ? nil : onHost.first) ?? choices.first)?.id
    }

    private static let previewLength = 4000

    /// The start of a long text; all of it goes into the file.
    private var previewText: String {
        request.text.count > Self.previewLength ? String(request.text.prefix(Self.previewLength)) + " …" : request.text
    }

    private func handOver(_ choices: [Choice]) {
        guard let choice = choices.first(where: { $0.id == selection }) else { return }
        // Kept for next time; an empty prompt is the default one.
        Handoff.prompt = prompt
        let share = PendingShare(
            hostID: choice.hostID,
            workspaceID: choice.workspaceID,
            paneID: choice.paneID,
            text: Handoff.prompt,
            images: [],
            handoff: request.text,
            created: .now,
            // Opened right here, not again when the app becomes active.
            opened: true
        )
        do {
            try PendingShare.save(share, imageData: [])
        } catch {
            self.error = error.localizedDescription
            return
        }
        store.notifier.openRequest = SpaceRef(hostID: choice.hostID, workspaceID: choice.workspaceID, paneID: choice.paneID)
        // The agent's composer may be on screen already.
        NotificationCenter.default.post(name: PendingShare.arrived, object: nil)
        dismiss()
    }
}
#endif
