import SwiftUI

/// The selected pane: header with state, then the live screen.
struct PaneDetailView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let selection: PaneRef?
    @State private var model = PaneModel(recordsVisits: true)
    @State private var search = PaneSearchState()
    @State private var showingConversation = false
    @State private var showingDiff = false
    @State private var showingFiles = false
    #if os(macOS)
    /// Why "In VS Code öffnen" failed (#288).
    @State private var editorError: String?
    #endif
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false
    /// The pane's buttons sit in the vertical bar of an iPhone Duo (#215).
    @State private var verticalBar = false
    #if !os(tvOS)
    /// Reading Claude's replies aloud and the voice mode (#297).
    @State private var voice = AgentVoice()
    #endif

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
                    summaryBar(connection: connection, paneID: selection.paneID)
                    voiceBar
                    screen(connection: connection, search: search.highlight(matches))
                    if connection.config.inputAllowed, let pane = pane(connection, selection.paneID) {
                        Divider()
                        InputBar(connection: connection, pane: pane, question: model.question)
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
        .onChange(of: selection) {
            search.matchIndex = nil
            #if !os(tvOS)
            voice.stop()
            #endif
        }
        #if !os(tvOS)
        // Reads a reply once Claude has finished (#297); a new pane is no
        // state change.
        .onChange(of: VoiceKey(pane: selection, state: claudeState)) { old, new in
            guard old.pane == new.pane, let selection, let connection = store.connection(for: selection.hostID) else { return }
            voice.agentStateChanged(from: old.state, to: new.state, connection: connection, paneID: selection.paneID)
        }
        #endif
        // A visit ends when the pane is left or the app goes away (#273).
        .onChange(of: scenePhase) { old, new in
            if new == .background {
                model.leave()
                #if !os(tvOS)
                // Without the app in front the connection does not last.
                voice.stop()
                #endif
            } else if old == .background, new != .background {
                model.arm()
            }
        }
        .onAppear { model.arm() }
        .onDisappear {
            model.leave()
            #if !os(tvOS)
            voice.stop()
            #endif
        }
        #if os(macOS)
        // A Mac app seldom goes to the background; quitting ends the visit.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.leave()
        }
        #endif
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
        #if os(macOS)
        .editorErrorAlert($editorError)
        #endif
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
            #if !os(tvOS)
            showingFiles = DemoMode.view == "files"
            #endif
            if let prompt = DemoMode.history, !prompt.isEmpty, let selection {
                PromptHistory.shared.record(prompt, for: PromptHistory.key(host: selection.hostID, pane: selection.paneID))
            }
        }
    }

    private struct FollowKey: Hashable {
        let pane: PaneRef?
        let generation: Int?
    }

    private struct VoiceKey: Equatable {
        let pane: PaneRef?
        let state: AgentState?
    }

    /// The agent state of the selected pane while Claude runs in it.
    private var claudeState: AgentState? {
        guard let selection, let connection = store.connection(for: selection.hostID),
              let pane = pane(connection, selection.paneID), pane.agent == "claude" else { return nil }
        return pane.agentState
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
            #if !os(tvOS)
            AgentVoiceMenu(voice: voice, connection: connection, paneID: paneID, agentState: pane?.agentState)
            #endif
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
        #if os(macOS)
        OpenInVSCodeButton(connection: connection, target: .pane(paneID), error: $editorError)
            .labelStyle(.iconOnly)
            .help(String(localized: "Arbeitsverzeichnis der Pane in VS Code öffnen"))
        #endif
        SelectTextButton(title: pane?.title.isEmpty == false ? pane!.title : paneID) {
            model.content?.plainText ?? ""
        }
        .disabled(model.content == nil)
        PaneSearchButton(state: search)
        TerminalZoomMenu()
    }

    /// Offers a summary of what is new since the last visit (#273), only
    /// where the on-device model is there.
    @ViewBuilder
    private func summaryBar(connection: HostConnection, paneID: String) -> some View {
        #if canImport(FoundationModels) && !os(tvOS)
        if let visit = model.summaryOffer, PaneSummary.isAvailable {
            PaneSummaryBar(
                connection: connection,
                paneID: paneID,
                agent: pane(connection, paneID)?.agent,
                visit: visit,
                unwrap: wrapLines,
                dismiss: model.dismissSummary
            )
            // A new pane or visit starts a new summary.
            .id("\(connection.id)/\(paneID)/\(visit.seen.timeIntervalSinceReferenceDate)")
            Divider()
        }
        #endif
    }

    @ViewBuilder
    private var voiceBar: some View {
        #if !os(tvOS)
        if voice.voiceMode || voice.error != nil {
            AgentVoiceBar(voice: voice)
            Divider()
        }
        #endif
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
