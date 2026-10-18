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

/// Matching for the switcher: every word of the query must appear in one of
/// the entry's texts, as a substring or, failing that, as letters in order
/// ("hrc" finds "herdr-remote-core"). Word starts rank above substrings,
/// substrings above scattered letters, the first field above the others.
enum SwitcherMatch {
    static func filter(_ entries: [SwitcherEntry], query: String) -> [SwitcherEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.enumerated()
            .compactMap { index, entry in
                score(entry.fields, words).map { (score: $0, index: index, entry: entry) }
            }
            .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
            .map(\.entry)
    }

    /// `nil` when a word matches nowhere.
    static func score(_ fields: [String], _ words: [String]) -> Int? {
        let fields = fields.map { $0.lowercased() }
        var total = 0
        for word in words {
            var best: Int?
            for (position, field) in fields.enumerated() {
                // The first field (name) weighs a little more.
                let bonus = position == 0 ? 1 : 0
                let points: Int? = if let range = field.range(of: word) {
                    (startsWord(field, at: range.lowerBound) ? 6 : 4) + bonus
                } else if isSubsequence(word, of: field) {
                    1
                } else {
                    nil
                }
                if let points, points > (best ?? 0) { best = points }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    private static func startsWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !before.isLetter && !before.isNumber
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = word[...]
        for char in text where char == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}

/// ⌘K: search spaces and agents on all hosts and jump there. Arrow keys move
/// the highlight, Return opens it, Esc closes.
struct QuickSwitcher: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onPick: (SpaceRef) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = SwitcherMatch.filter(SwitcherEntry.all(in: store), query: query)
        let showHost = store.connections.count > 1
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Space oder Agent suchen", text: $query)
                    .technicalInput()
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .focused($searchFocused)
                    .onSubmit { pick(current(in: results)) }
                    .onKeyPress(.downArrow) { move(1, in: results) }
                    .onKeyPress(.upArrow) { move(-1, in: results) }
                    .padding(10)
                Divider()
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollViewReader { proxy in
                        List(results) { entry in
                            Button {
                                pick(entry)
                            } label: {
                                SwitcherRow(entry: entry, showHost: showHost)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                entry.id == current(in: results)?.id ? Color.accentColor.opacity(0.2) : Color.clear
                            )
                            .id(entry.id)
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
        }
        .onChange(of: query) { highlighted = nil }
        .onAppear { searchFocused = true }
        #if os(macOS)
        .frame(width: 520, height: 440)
        #endif
    }

    /// The highlighted entry, or the best match when nothing was moved yet.
    private func current(in results: [SwitcherEntry]) -> SwitcherEntry? {
        results.first { $0.id == highlighted } ?? results.first
    }

    private func move(_ step: Int, in results: [SwitcherEntry]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let index = results.firstIndex { $0.id == current(in: results)?.id } ?? 0
        highlighted = results[min(max(index + step, 0), results.count - 1)].id
        return .handled
    }

    private func pick(_ entry: SwitcherEntry?) {
        guard let entry else { return }
        onPick(entry.target)
        dismiss()
    }
}

private struct SwitcherRow: View {
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
