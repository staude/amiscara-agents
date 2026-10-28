import SwiftUI

/// The selected pane: header with state, then the live screen.
struct PaneDetailView: View {
    @Environment(HostStore.self) private var store
    let selection: PaneRef?
    @State private var model = PaneModel()
    @State private var search = PaneSearchState()
    @State private var showingConversation = false
    @State private var showingDiff = false
    @State private var showingFiles = false
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false
    /// The pane's buttons sit in the vertical bar of an iPhone Duo (#215).
    @State private var verticalBar = false

    var body: some View {
        let matches = search.matches(in: model.content)
        return Group {
            if let selection, let connection = store.connection(for: selection.hostID) {
                VStack(spacing: 0) {
                    header(connection: connection, paneID: selection.paneID)
                        #if os(tvOS)
                        // Rows for the remote: header, terminal, input.
                        .focusSection()
                        #endif
                    Divider()
                    if search.isOpen {
                        PaneSearchBar(state: search, matches: matches)
                        Divider()
                    }
                    screen(connection: connection, search: search.highlight(matches))
                    if connection.config.inputAllowed, let pane = pane(connection, selection.paneID) {
                        Divider()
                        InputBar(connection: connection, pane: pane)
                            #if os(tvOS)
                            .focusSection()
                            #endif
                    }
                }
                .toolbar {
                    if verticalBar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            actions(connection: connection, paneID: selection.paneID)
                        }
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
        // A new session (e.g. after coming back to the foreground) ended the
        // old follower, so the generation is part of the key. No stop on
        // disappearing, see `PaneModel.show`.
        .onChange(of: FollowKey(pane: selection, generation: store.connection(for: selection?.hostID)?.generation), initial: true) {
            model.show(paneID: selection?.paneID, on: store.connection(for: selection?.hostID))
        }
        .onChange(of: selection) { search.matchIndex = nil }
        // For the header while the host does not know the pane (#276).
        .onChange(of: currentTitle, initial: true) { _, title in
            guard let selection, let title, !title.isEmpty else { return }
            PaneCache.shared.setTitle(title, host: selection.hostID, pane: selection.paneID)
        }
        .onChange(of: wrapLines, initial: true) { model.setUnwrap(wrapLines) }
        .sheet(isPresented: $showingConversation) {
            if let selection, let connection = store.connection(for: selection.hostID) {
                ConversationView(connection: connection, paneID: selection.paneID)
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: $showingDiff) {
            if let selection, let connection = store.connection(for: selection.hostID) {
                DiffView(connection: connection, paneID: selection.paneID)
            }
        }
        .sheet(isPresented: $showingFiles) {
            if let selection, let connection = store.connection(for: selection.hostID) {
                FileBrowserView(connection: connection, paneID: selection.paneID)
            }
        }
        #endif
        .tracksVerticalBar($verticalBar)
        .focusedSceneValue(\.paneSearch, selection == nil ? nil : search.actions(matches))
        .task(id: selection) {
            // The screenshot demo (#199) opens these for its pane.
            guard DemoMode.isOn, selection?.paneID == DemoMode.pane else { return }
            if let query = DemoMode.search, !query.isEmpty {
                search.isOpen = true
                search.query = query
            }
            showingConversation = DemoMode.view == "conversation"
            if let prompt = DemoMode.history, !prompt.isEmpty, let selection {
                PromptHistory.shared.record(prompt, for: PromptHistory.key(host: selection.hostID, pane: selection.paneID))
            }
        }
    }

    private struct FollowKey: Hashable {
        let pane: PaneRef?
        let generation: Int?
    }

    private var currentTitle: String? {
        guard let selection, let connection = store.connection(for: selection.hostID) else { return nil }
        return pane(connection, selection.paneID)?.title
    }

    /// The pane's title, the one kept from before while the host does not
    /// know the pane, else its ID.
    private func title(_ pane: PaneItem?, connection: HostConnection, paneID: String) -> String {
        if let pane { return pane.title.isEmpty ? paneID : pane.title }
        return PaneCache.shared.entry(host: connection.id, pane: paneID)?.title ?? paneID
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
            Text(title(pane, connection: connection, paneID: paneID))
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
            if !verticalBar {
                actions(connection: connection, paneID: paneID)
            }
        }
        // Here, not on the buttons: a styled button stays out of the
        // vertical bar.
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Conversation, changes, files, text selection, search and font size:
    /// in the header, or in the vertical bar where there is one.
    @ViewBuilder
    private func actions(connection: HostConnection, paneID: String) -> some View {
        let pane = pane(connection, paneID)
        if pane?.agent == "claude" {
            Button("Gesprächsverlauf", systemImage: "text.bubble") {
                showingConversation = true
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Gesprächsverlauf aus der Claude-Sitzung"))
        }
        #if !os(tvOS)
        if connection.config.inputAllowed {
            Button("Änderungen", systemImage: "plusminus") {
                showingDiff = true
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Git-Änderungen im Arbeitsverzeichnis der Pane"))
        }
        // Read only: also for hosts without input.
        Button("Dateien", systemImage: "folder") {
            showingFiles = true
        }
        .labelStyle(.iconOnly)
        .help(String(localized: "Dateien im Arbeitsverzeichnis der Pane"))
        #endif
        SelectTextButton(title: pane?.title.isEmpty == false ? pane!.title : paneID) {
            model.content?.plainText ?? ""
        }
        .disabled(model.content == nil)
        PaneSearchButton(state: search)
        TerminalZoomMenu()
    }

    @ViewBuilder
    private func screen(connection: HostConnection, search: SearchHighlight) -> some View {
        if let content = model.content {
            TerminalScreenView(content: content, history: model, search: search)
                .terminalZoomGesture()
                .opacity(connection.isLive ? 1 : 0.5)
                .overlay(alignment: .top) {
                    if !connection.isLive {
                        StaleBanner(connection: connection, updatedAt: model.updatedAt)
                    } else if let error = model.error {
                        Banner(text: error, systemImage: "exclamationmark.triangle")
                    }
                }
        } else if let error = model.error {
            ContentUnavailableView("Pane nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Over the last screen while the host is not live (#276): since when the
/// screen is unchanged, and whether the app is still trying to connect.
struct StaleBanner: View {
    let connection: HostConnection
    let updatedAt: Date?

    var body: some View {
        Banner(text: text, systemImage: "wifi.slash")
    }

    /// A stopped session (refused login, host key) does not try again.
    private var gaveUp: Bool {
        if connection.startError != nil || connection.needsHostKeyDecision { return true }
        if case .failed = connection.status { return true }
        return false
    }

    private var text: String {
        guard let updatedAt else {
            return gaveUp ? String(localized: "Keine Verbindung") : String(localized: "Verbindung wird aufgebaut")
        }
        let time = Calendar.current.isDateInToday(updatedAt)
            ? updatedAt.formatted(date: .omitted, time: .shortened)
            : updatedAt.formatted(date: .abbreviated, time: .shortened)
        return gaveUp
            ? String(localized: "Stand von \(time), keine Verbindung")
            : String(localized: "Stand von \(time), Verbindung wird aufgebaut")
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .selectableText()
            .padding(.top, 8)
    }
}
