import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @State private var selection: SpaceRef?
    @State private var editing: HostConfig?
    @State private var dismissedKeyPrompts: Set<UUID> = []
    /// An opened "add host" link and the new host it is meant for.
    @State private var pendingImport: (hostID: UUID, link: String)?
    @State private var switching = false

    var body: some View {
        // Two columns like herdr: spaces and agents on the left, the space
        // with its tabs on the right. On iPhone the sidebar is the start screen.
        NavigationSplitView {
            HostSidebar(selection: $selection, editing: $editing, switching: $switching)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            WorkspaceDetailView(selection: $selection)
        }
        .onChange(of: store.notifier.openRequest, initial: true) { _, request in
            // A tapped notification, menu bar entry or shortcut opens its
            // pane. Initial, because the request may be what launched the app
            // or, on the Mac, what opened this window.
            guard let request else { return }
            selection = request
            store.notifier.openRequest = nil
        }
        .focusedSceneValue(\.navigator, Navigator(
            openSwitcher: { switching = true },
            spaceCount: currentSpaces.count,
            selectSpace: selectSpace
        ))
        .sheet(isPresented: $switching) {
            QuickSwitcher { selection = $0 }
        }
        .onDisappear {
            // A closed window shows no pane; its agents get banners again.
            store.notifier.visiblePane = nil
        }
        .sheet(item: $editing) { config in
            HostEditorView(config: config, importLink: pendingImport?.hostID == config.id ? pendingImport?.link : nil)
        }
        .onChange(of: editing?.id) { _, id in
            // Applied once: closing the editor or opening another drops it.
            if pendingImport?.hostID != id { pendingImport = nil }
        }
        .onOpenURL { url in
            // amiscara-agents://add-host?... from a QR code or a pasted link.
            guard url.scheme?.lowercased() == "amiscara-agents" else { return }
            let config = HostConfig(name: "", kind: .ssh)
            pendingImport = (config.id, url.absoluteString)
            editing = config
        }
        // Open links in the existing window instead of a new one.
        .handlesExternalEvents(preferring: ["amiscara-agents"], allowing: ["*"])
        .sheet(item: keyPrompt) { connection in
            HostKeyView(connection: connection) {
                dismissedKeyPrompts.insert(connection.id)
            }
        }
    }

    /// The spaces of the selected host in sidebar order; without a selection
    /// those of the first host that has any.
    private var currentSpaces: [(hostID: UUID, workspaceID: String)] {
        let connection = store.connection(for: selection?.hostID)
            ?? store.connections.first { !($0.update?.workspaces.isEmpty ?? true) }
        guard let connection, let update = connection.update else { return [] }
        return SpaceOrder.arrange(update).map { (connection.id, $0.workspace.workspaceId) }
    }

    /// ⌘1 to ⌘9, counted like the sidebar shows them.
    private func selectSpace(_ number: Int) {
        let spaces = currentSpaces
        guard number >= 1, number <= spaces.count else { return }
        let space = spaces[number - 1]
        selection = SpaceRef(hostID: space.hostID, workspaceID: space.workspaceID)
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
