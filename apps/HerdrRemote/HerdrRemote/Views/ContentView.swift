import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @State private var selection: PaneRef?
    @State private var editing: HostConfig?
    @State private var dismissedKeyPrompts: Set<UUID> = []
    /// On iPhone the split view collapses; start on the board.
    @State private var compactColumn = NavigationSplitViewColumn.content

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            SidebarView(selection: $selection, editing: $editing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            BoardView(selection: $selection, editing: $editing)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            PaneDetailView(selection: selection)
        }
        .sheet(item: $editing) { config in
            HostEditorView(config: config)
        }
        .sheet(item: keyPrompt) { connection in
            HostKeyView(connection: connection) {
                dismissedKeyPrompts.insert(connection.id)
            }
        }
    }

    /// The first host waiting for a host key decision the user has not put off.
    private var pendingKeyPrompt: HostConnection? {
        store.connections.first { connection in
            !dismissedKeyPrompts.contains(connection.id) && connection.needsHostKeyDecision
        }
    }

    private var keyPrompt: Binding<HostConnection?> {
        Binding(
            get: { pendingKeyPrompt },
            set: { value in
                if value == nil, let pending = pendingKeyPrompt {
                    dismissedKeyPrompts.insert(pending.id)
                }
            }
        )
    }
}

/// Opens the host editor for a new SSH host. Lives in the columns, not on the
/// split view: iPad and iPhone do not show toolbar items attached there.
struct AddHostButton: View {
    @Binding var editing: HostConfig?

    var body: some View {
        Button("Host hinzufügen", systemImage: "plus") {
            editing = HostConfig(name: "", kind: .ssh)
        }
    }
}

extension HostConnection {
    var needsHostKeyDecision: Bool {
        switch status {
        case .hostKeyUnknown, .hostKeyChanged: true
        default: false
        }
    }
}
