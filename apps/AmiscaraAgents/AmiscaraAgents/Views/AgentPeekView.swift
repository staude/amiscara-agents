import SwiftUI

#if !os(tvOS)
/// An agent to look into without leaving the current view (#332).
struct AgentPeek: Identifiable, Hashable {
    let hostID: UUID
    let workspaceID: String
    let paneID: String

    var id: String { "\(hostID)/\(paneID)" }

    var spaceRef: SpaceRef {
        SpaceRef(hostID: hostID, workspaceID: workspaceID, paneID: paneID)
    }
}

/// The peek: the agent's live pane and its input bar over the current view,
/// which stays as it was. "Öffnen" switches there for real; Esc, the close
/// button or a swipe down close the overlay. Esc never reaches the agent
/// here, only the key bar's Esc does.
struct AgentPeekView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let peek: AgentPeek
    let open: (SpaceRef) -> Void

    /// No visits: "what is new" stays for really opening the pane (#273).
    @State private var model = PaneModel()
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false
    /// The pane on screen before the peek, for the notifier.
    @State private var previousVisible: (hostID: UUID, paneID: String)?
    @State private var opened = false

    var body: some View {
        let connection = store.connection(for: peek.hostID)
        VStack(spacing: 0) {
            header(connection)
            Divider()
            if let connection {
                let pane = pane(connection)
                if pane == nil, connection.update != nil {
                    ContentUnavailableView("Agent nicht mehr da", systemImage: "sparkles")
                } else {
                    screen(connection)
                    if connection.config.inputAllowed, let pane {
                        Divider()
                        InputBar(connection: connection, pane: pane, question: model.question, escapeToAgent: false)
                    }
                }
            } else {
                ContentUnavailableView("Keine Verbindung", systemImage: "wifi.slash")
            }
        }
        // A new session ended the old follower, see `PaneDetailView`.
        .onChange(of: FollowKey(peek: peek, generation: connection?.generation), initial: true) {
            model.show(paneID: peek.paneID, on: store.connection(for: peek.hostID))
        }
        .onChange(of: wrapLines, initial: true) { model.setUnwrap(wrapLines) }
        // The peeked agent is on screen: no banner for it meanwhile.
        .onAppear {
            previousVisible = store.notifier.visiblePane
            store.notifier.visiblePane = (hostID: peek.hostID, paneID: peek.paneID)
        }
        .onDisappear {
            // Opened, the pane stays on screen; the space sets it itself.
            guard !opened, let visible = store.notifier.visiblePane,
                  visible.hostID == peek.hostID, visible.paneID == peek.paneID
            else { return }
            store.notifier.visiblePane = previousVisible
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 640)
        #else
        .presentationSizing(.page)
        .presentationDragIndicator(.visible)
        #endif
    }

    private struct FollowKey: Hashable {
        let peek: AgentPeek
        let generation: Int?
    }

    private func pane(_ connection: HostConnection) -> PaneItem? {
        connection.update?.workspaces
            .flatMap(\.tabs).flatMap(\.panes)
            .first { $0.paneId == peek.paneID }
    }

    /// The pane's title, the one kept from before while the host does not
    /// know the pane, else its ID.
    private func title(_ pane: PaneItem?) -> String {
        if let pane { return pane.title.isEmpty ? peek.paneID : pane.title }
        return PaneCache.shared.entry(host: peek.hostID, pane: peek.paneID)?.title ?? peek.paneID
    }

    private func header(_ connection: HostConnection?) -> some View {
        let pane = connection.flatMap(pane)
        return HStack(spacing: 8) {
            StatusDot(state: pane?.agent == nil ? nil : pane?.agentState)
            Text(title(pane))
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
            if let connection {
                Text(connection.config.name).foregroundStyle(.secondary)
            }
            Button("Öffnen") {
                opened = true
                open(peek.spaceRef)
                dismiss()
            }
            .disabled(connection == nil)
            Button("Schließen", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func screen(_ connection: HostConnection) -> some View {
        if let content = model.content {
            TerminalScreenView(content: content, history: model)
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

extension View {
    /// Shows the peek of `item` as a sheet; `open` switches to its space.
    func agentPeek(_ item: Binding<AgentPeek?>, open: @escaping (SpaceRef) -> Void) -> some View {
        sheet(item: item) { peek in
            AgentPeekView(peek: peek, open: open)
        }
    }

    /// "Kurz ansehen" and "Öffnen" for an agent's row: right-click on the
    /// Mac, long press on iPhone and iPad. No menu without `peek`.
    func peekMenu(_ peek: AgentPeek?, open: @escaping (SpaceRef) -> Void, peekAction: @escaping (AgentPeek) -> Void) -> some View {
        contextMenu {
            if let peek {
                Button("Kurz ansehen", systemImage: "eye") { peekAction(peek) }
                Button("Öffnen", systemImage: "arrow.forward.circle") { open(peek.spaceRef) }
            }
        }
    }
}
#endif
