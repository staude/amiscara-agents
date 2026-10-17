import SwiftUI

/// The selected pane: header with state, then the live screen.
struct PaneDetailView: View {
    @Environment(HostStore.self) private var store
    let selection: PaneRef?
    @State private var model = PaneModel()
    @State private var searching = false
    @State private var query = ""
    /// Index into the current matches; `nil` means the last one, nearest
    /// to the bottom where the view starts.
    @State private var matchIndex: Int?
    @State private var scrollRequest = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = searching ? PaneSearch.matches(of: query, in: model.content?.lines ?? []) : []
        return Group {
            if let selection, let connection = store.connection(for: selection.hostID) {
                VStack(spacing: 0) {
                    header(connection: connection, paneID: selection.paneID)
                    Divider()
                    if searching {
                        searchBar(matches: matches)
                        Divider()
                    }
                    screen(connection: connection, search: highlight(matches))
                    if connection.config.inputAllowed, let pane = pane(connection, selection.paneID) {
                        Divider()
                        InputBar(connection: connection, pane: pane)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Keine Pane gewählt",
                    systemImage: "terminal",
                    description: Text("Wählen Sie links einen Agent oder eine Pane.")
                )
            }
        }
        .onChange(of: selection, initial: true) { _, selection in
            model.show(paneID: selection?.paneID, on: store.connection(for: selection?.hostID))
            matchIndex = nil
        }
        .onChange(of: query) {
            matchIndex = nil
            scrollRequest += 1
        }
        .onDisappear { model.stop() }
    }

    private func pane(_ connection: HostConnection, _ paneID: String) -> PaneItem? {
        connection.update?.workspaces
            .flatMap(\.tabs).flatMap(\.panes)
            .first { $0.paneId == paneID }
    }

    private func header(connection: HostConnection, paneID: String) -> some View {
        let pane = pane(connection, paneID)
        return HStack(spacing: 8) {
            StatusDot(state: pane?.agent == nil ? nil : pane?.agentState)
            Text(pane?.title.isEmpty == false ? pane!.title : paneID)
                .font(.headline)
                .lineLimit(1)
            if let agent = pane?.agent {
                Text(agent).foregroundStyle(.secondary)
            }
            Spacer()
            if let state = pane?.agentState, pane?.agent != nil {
                Text(state.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(state.color)
            }
            Text(connection.config.name).foregroundStyle(.secondary)
            Button("Suchen", systemImage: "magnifyingglass", action: openSearch)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: .command)
                .help("In der Pane suchen (⌘F)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func screen(connection: HostConnection, search: SearchHighlight) -> some View {
        if let content = model.content {
            TerminalScreenView(content: content, search: search)
                .overlay(alignment: .top) {
                    if let error = model.error {
                        Banner(text: error, systemImage: "exclamationmark.triangle")
                    } else if !connection.isLive {
                        Banner(text: String(localized: "Verbindung unterbrochen, Inhalt veraltet"), systemImage: "wifi.slash")
                    }
                }
        } else if let error = model.error {
            ContentUnavailableView("Pane nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Search

    private func openSearch() {
        searching = true
        searchFocused = true
    }

    private func closeSearch() {
        searching = false
        query = ""
        matchIndex = nil
    }

    /// The current match's position, kept in range while live output
    /// changes the number of matches.
    private func currentIndex(_ matches: [SearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return min(matchIndex ?? matches.count - 1, matches.count - 1)
    }

    private func step(_ delta: Int, in matches: [SearchMatch]) {
        guard let index = currentIndex(matches) else { return }
        matchIndex = (index + delta + matches.count) % matches.count
        scrollRequest += 1
    }

    private func highlight(_ matches: [SearchMatch]) -> SearchHighlight {
        SearchHighlight(
            byLine: Dictionary(grouping: matches, by: \.line),
            current: currentIndex(matches).map { matches[$0] },
            scrollRequest: scrollRequest
        )
    }

    private func searchBar(matches: [SearchMatch]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("In der Pane suchen", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    step(1, in: matches)
                    searchFocused = true
                }
            if !query.isEmpty {
                if let index = currentIndex(matches) {
                    Text("\(index + 1) von \(matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Keine Treffer").foregroundStyle(.secondary)
                }
            }
            Button("Vorheriger Treffer", systemImage: "chevron.up") { step(-1, in: matches) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(matches.isEmpty)
            Button("Nächster Treffer", systemImage: "chevron.down") { step(1, in: matches) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(matches.isEmpty)
            Button("Suche schließen", systemImage: "xmark.circle.fill", action: closeSearch)
                .keyboardShortcut(.cancelAction)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
    }
}
