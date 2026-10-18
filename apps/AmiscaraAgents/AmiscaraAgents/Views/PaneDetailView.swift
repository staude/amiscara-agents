import SwiftUI

/// The selected pane: header with state, then the live screen.
struct PaneDetailView: View {
    @Environment(HostStore.self) private var store
    let selection: PaneRef?
    @State private var model = PaneModel()
    @State private var search = PaneSearchState()

    var body: some View {
        let matches = search.matches(in: model.content)
        return Group {
            if let selection, let connection = store.connection(for: selection.hostID) {
                VStack(spacing: 0) {
                    header(connection: connection, paneID: selection.paneID)
                    Divider()
                    if search.isOpen {
                        PaneSearchBar(state: search, matches: matches)
                        Divider()
                    }
                    screen(connection: connection, search: search.highlight(matches))
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
            search.matchIndex = nil
        }
        // A new session (e.g. after coming back to the foreground) ended the
        // old follower.
        .onChange(of: store.connection(for: selection?.hostID)?.generation) {
            model.show(paneID: selection?.paneID, on: store.connection(for: selection?.hostID))
        }
        .focusedSceneValue(\.paneSearch, selection == nil ? nil : search.actions(matches))
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
            PaneSearchButton(state: search)
            TerminalZoomMenu()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func screen(connection: HostConnection, search: SearchHighlight) -> some View {
        if let content = model.content {
            TerminalScreenView(content: content, history: model, search: search)
                .terminalZoomGesture()
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
            .padding(.top, 8)
    }
}
