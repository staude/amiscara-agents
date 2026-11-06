import SwiftUI

/// One thing to jump to: a space or an agent on some host.
struct SwitcherEntry: Identifiable {
    enum Kind { case space, agent }

    let kind: Kind
    let target: SpaceRef
    let title: String
    let subtitle: String?
    let hostName: String
    /// `nil` for a space without agents.
    let state: AgentState?
    /// The texts a query is matched against, most important first.
    let fields: [String]

    var id: String {
        "\(target.hostID)/\(target.workspaceID)/\(target.paneID ?? "")"
    }

    /// Spaces in sidebar order, then agents in herdr's grouped order, per host.
    @MainActor
    static func all(in store: HostStore) -> [SwitcherEntry] {
        store.connections.flatMap { connection -> [SwitcherEntry] in
            guard let update = connection.update else { return [] }
            let host = connection.config.name
            let spaces = SpaceOrder.arrange(update).map { entry in
                let ws = entry.workspace
                // A grouped space reads "Dorfkino" with "Privat" below; the
                // full name "Privat/Dorfkino" still matches.
                let subtitle = entry.nested ? ws.label : [ws.group, ws.branch].compactMap { $0 }.joined(separator: " · ")
                return SwitcherEntry(
                    kind: .space,
                    target: SpaceRef(hostID: connection.id, workspaceID: ws.workspaceId),
                    title: entry.nested ? (ws.branch ?? ws.worktreeName ?? ws.label) : ws.name,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    hostName: host,
                    state: ws.agentState == .unknown ? nil : ws.agentState,
                    fields: [ws.name, ws.label, ws.branch, ws.worktreeName].compactMap { $0 }
                )
            }
            let agents = AgentOrder.sorted(update, by: .grouped).map { entry in
                let agent = entry.agent
                let place = entry.tabNumber.map { "\(agent.spacePlace) · \($0)" } ?? agent.spacePlace
                return SwitcherEntry(
                    kind: .agent,
                    target: SpaceRef(hostID: connection.id, workspaceID: agent.workspaceId, paneID: agent.paneId),
                    title: agent.agent,
                    subtitle: agent.title.isEmpty ? place : "\(place) · \(agent.title)",
                    hostName: host,
                    state: agent.agentState,
                    fields: [agent.agent, agent.workspaceLabel, agent.title, agent.tabLabel]
                )
            }
            return spaces + agents
        }
    }
}

/// A row of the switcher.
typealias SwitcherResult = PaletteResult<SwitcherEntry, PaletteCommand>

extension PaletteResult: Identifiable where Entry == SwitcherEntry, Command == PaletteCommand {
    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .command(let command): "cmd:\(command.id)"
        }
    }
}

/// ⌘K: search spaces and agents on all hosts and jump there, or the
/// commands of the focused space and pane (#346), `>` for commands only.
/// Arrow keys move the highlight, Return opens it or runs the command,
/// ⌥Return peeks into an agent (#332), Esc closes. Closing the peek comes
/// back here.
struct QuickSwitcher: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Collected when the switcher opened: inside the sheet the focused
    /// values of the window are gone.
    var commands: [PaletteCommand] = []
    /// Runs the command once the switcher is closed, so a command that opens
    /// a sheet or a confirmation finds the window free.
    var onCommand: (PaletteCommand) -> Void = { _ in }
    let onPick: (SpaceRef) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    #if !os(tvOS)
    @State private var peeking: AgentPeek?
    /// Opened from the peek: picked once the peek is gone.
    @State private var pendingPick: SpaceRef?
    #endif
    @FocusState private var searchFocused: Bool

    var body: some View {
        let palette = PaletteQuery.parse(query)
        let results = PaletteResults.combine(
            entries: SwitcherEntry.all(in: store),
            entryFields: \.fields,
            commands: commands,
            commandFields: \.fields,
            query: palette
        )
        let showHost = store.connections.count > 1
        NavigationStack {
            VStack(spacing: 0) {
                TextField(searchPrompt, text: $query)
                    .technicalInput()
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .focused($searchFocused)
                    .onSubmit {
                        // The field editor may take ⌥Return as a submit.
                        #if !os(tvOS)
                        if Platform.optionKeyDown, let peek = current(in: results).flatMap(peek) {
                            peeking = peek
                            return
                        }
                        #endif
                        pick(current(in: results))
                    }
                    #if !os(tvOS)
                    .onKeyPress(.return, phases: .down) { press in
                        // A space has no peek: ⌥Return opens it like Return.
                        guard press.modifiers.contains(.option),
                              let peek = current(in: results).flatMap(peek)
                        else { return .ignored }
                        peeking = peek
                        return .handled
                    }
                    #endif
                    .onKeyPress(.downArrow) { move(1, in: results) }
                    .onKeyPress(.upArrow) { move(-1, in: results) }
                    .padding(10)
                Divider()
                if results.isEmpty {
                    // The app's own commands are always there, so only a
                    // query can leave the list empty.
                    ContentUnavailableView.search(text: palette.text)
                } else {
                    ScrollViewReader { proxy in
                        List(results) { result in
                            Button {
                                pick(result)
                            } label: {
                                switch result {
                                case .entry(let entry): SwitcherRow(entry: entry, showHost: showHost)
                                case .command(let command): CommandRow(command: command)
                                }
                            }
                            .buttonStyle(.plain)
                            #if !os(tvOS)
                            .peekMenu(peek(result), open: { _ in pick(result) }) { peeking = $0 }
                            #endif
                            .listRowBackground(
                                result.id == current(in: results)?.id ? Color.accentColor.opacity(0.2) : Color.clear
                            )
                            .id(result.id)
                        }
                        .listStyle(.plain)
                        .onChange(of: highlighted) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            .navigationTitle("Wechseln zu")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        #if !os(tvOS)
                        .keyboardShortcut(.cancelAction)
                        #endif
                }
            }
            #if !os(tvOS)
            // The peek closes before the switcher it sits on: a Mac sheet
            // closed with a sheet on it can leave one behind.
            .agentPeek($peeking, onDismiss: {
                guard let target = pendingPick else { return }
                pendingPick = nil
                onPick(target)
                dismiss()
            }) { target in
                pendingPick = target
                peeking = nil
            }
            #endif
        }
        .onChange(of: query) { highlighted = nil }
        .onAppear { searchFocused = true }
        #if os(macOS)
        .frame(width: 520, height: 440)
        #endif
    }

    /// tvOS has no commands (#346).
    private var searchPrompt: LocalizedStringKey {
        #if os(tvOS)
        "Space oder Agent suchen"
        #else
        "Space, Agent oder > Befehl"
        #endif
    }

    /// The highlighted entry, or the best match when nothing was moved yet.
    private func current(in results: [SwitcherResult]) -> SwitcherResult? {
        results.first { $0.id == highlighted } ?? results.first
    }

    private func move(_ step: Int, in results: [SwitcherResult]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let index = results.firstIndex { $0.id == current(in: results)?.id } ?? 0
        highlighted = results[min(max(index + step, 0), results.count - 1)].id
        return .handled
    }

    #if !os(tvOS)
    /// The peek of an agent entry; spaces and commands have none.
    private func peek(_ result: SwitcherResult) -> AgentPeek? {
        guard case .entry(let entry) = result, entry.kind == .agent, let paneID = entry.target.paneID else { return nil }
        return AgentPeek(hostID: entry.target.hostID, workspaceID: entry.target.workspaceID, paneID: paneID)
    }
    #endif

    private func pick(_ result: SwitcherResult?) {
        switch result {
        case .entry(let entry): onPick(entry.target)
        case .command(let command): onCommand(command)
        case nil: return
        }
        dismiss()
    }
}

/// A command: its name, the section it belongs to and its shortcut.
struct CommandRow: View {
    let command: PaletteCommand

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: command.title).lineLimit(1)
            Text(verbatim: command.section.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let shortcut = command.shortcut {
                Text(verbatim: shortcut.display)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SwitcherRow: View {
    let entry: SwitcherEntry
    let showHost: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kind == .space ? "square.split.2x1" : "sparkles")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title).lineLimit(1)
                    if let state = entry.state, entry.kind == .agent, state != .idle {
                        Text(state.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(state.color)
                    }
                }
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if showHost {
                Text(entry.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let state = entry.state {
                StatusDot(state: state)
                    .padding(.top, 5)
            }
        }
        .contentShape(Rectangle())
    }
}
