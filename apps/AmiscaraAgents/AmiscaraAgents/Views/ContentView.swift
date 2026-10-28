import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @State private var selection: SpaceRef?
    /// The overview of all hosts (#274) is open instead of a space.
    @State private var showingOverview = false
    #if os(iOS)
    /// Compact, the split view collapses to a stack (iPhone).
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var editing: HostConfig?
    @State private var dismissedKeyPrompts: Set<UUID> = []
    /// An opened "add host" link and the new host it is meant for.
    @State private var pendingImport: (hostID: UUID, link: String)?
    @State private var switching = false
    /// Sidebar width that ends at the fold of an unfolded iPhone Duo (#215).
    @State private var foldWidth: CGFloat?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    #if os(iOS)
    /// An Apple TV's pairing code, scanned with the camera (#127).
    @State private var pairingTV: TVPairing.Link?
    #endif
    #if !os(tvOS)
    /// Text from the clipboard or a link, on its way to an agent (#236).
    @State private var handoff: Handoff.Request?
    #endif

    var body: some View {
        // Two columns like herdr: spaces and agents on the left, the space
        // with its tabs on the right. On iPhone the sidebar is the start screen.
        Group {
            #if os(tvOS)
            TVContentView(editing: $editing, open: $selection)
            #else
            NavigationSplitView {
                HostSidebar(selection: sidebarSelection, editing: $editing, switching: $switching, openHandoff: openHandoff)
                    .navigationSplitViewColumnWidth(min: foldWidth ?? 240, ideal: foldWidth ?? 280, max: foldWidth)
            } detail: {
                // Without a space chosen, Mac and iPad show the overview.
                if showingOverview || selection == nil {
                    OverviewView { selection = $0 }
                } else {
                    WorkspaceDetailView(selection: $selection)
                }
            }
            .sidebarAtFold($foldWidth)
            .overlay(alignment: .bottom) {
                // Pages agents on the hosts want opened (#247).
                OpenRequestBanner()
            }
            #endif
        }
        .onChange(of: selection) { _, selection in
            // A space opened from anywhere leaves the overview. Without a
            // space no pane is on screen, so its agent notifies again.
            if selection != nil {
                showingOverview = false
            } else {
                store.notifier.visiblePane = nil
            }
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
            selectSpace: selectSpace,
            openHandoff: openHandoff
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
        #if !os(tvOS)
        .sheet(item: $handoff) { request in
            HandoffSheet(request: request)
        }
        // A pane handed off from another device (#231); without a matching
        // host entry the app just opens.
        .onContinueUserActivity(PaneHandoff.activityType) { activity in
            guard let target = PaneHandoff.target(from: activity),
                  let ref = PaneHandoff.resolve(target, in: store)
            else { return }
            selection = ref
        }
        #endif
        .onOpenURL { url in
            #if os(iOS)
            if let link = TVPairing.Link(url) {
                pairingTV = link
                return
            }
            #endif
            #if !os(tvOS)
            // amiscara-agents://prompt?text=... from another tool (#236).
            if let request = Handoff.parsePromptURL(url) {
                store.notifier.dictateRequest = nil
                handoff = request
                return
            }
            // The Mac's share extension saved a share and opens the app.
            if url.scheme?.lowercased() == "amiscara-agents", url.host()?.lowercased() == "share" {
                store.notifier.dictateRequest = nil
                openPendingShare()
                return
            }
            #endif
            // amiscara-agents://open?... from a widget opens that pane.
            if let target = WidgetSnapshot.parseOpenURL(url) {
                let ref = SpaceRef(hostID: target.host, workspaceID: target.workspaceID, paneID: target.paneID)
                selection = ref
                // A control's "dictate to the last agent" (#227).
                store.notifier.dictateRequest = WidgetSnapshot.wantsDictation(url)
                    ? DictateRequest(hostID: target.host, paneID: target.paneID, at: .now)
                    : nil
                return
            }
            store.notifier.dictateRequest = nil
            // amiscara-agents://add-host?... from a QR code or a pasted link;
            // any other link (amiscara-agents://open) just opens the app.
            guard url.scheme?.lowercased() == "amiscara-agents", url.host()?.lowercased() == "add-host" else { return }
            let config = HostConfig(name: "", kind: .ssh)
            pendingImport = (config.id, url.absoluteString)
            editing = config
        }
        // Open links in the existing window instead of a new one.
        #if !os(tvOS)
        .handlesExternalEvents(preferring: ["amiscara-agents"], allowing: ["*"])
        #endif
        #if os(iOS)
        .sheet(item: $pairingTV) { link in
            TVPairSheet(link: link)
        }
        #endif
        #if os(tvOS)
        // Hosts the iPhone paired while the app was closed; then the home
        // network names their Mac apps published (no VPN on tvOS).
        .task {
            guard !DemoMode.isOn else { return }
            await store.adoptPairedHosts()
            await store.useHomeNetworkAddresses()
        }
        #endif
        #if os(macOS)
        // For Apple TVs in the home network; renewed hourly.
        .task {
            while !Task.isCancelled {
                await store.publishHomeNetworkName()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        #endif
        .sheet(item: keyPrompt) { connection in
            HostKeyView(connection: connection) {
                dismissedKeyPrompts.insert(connection.id)
            }
        }
        .task { await openDemo() }
    }

    /// Opens what the screenshot demo asks for (#199) once the demo
    /// session's spaces arrived.
    private func openDemo() async {
        guard DemoMode.isOn, let connection = store.connections.first else { return }
        for _ in 0..<100 {
            if let spaces = connection.update?.workspaces, !spaces.isEmpty {
                if let label = DemoMode.space, let space = spaces.first(where: { $0.label == label }) {
                    selection = SpaceRef(hostID: connection.id, workspaceID: space.workspaceId, paneID: DemoMode.pane)
                }
                switch DemoMode.view {
                case "switcher": switching = true
                case "addHost": editing = HostConfig(name: "", kind: .ssh)
                #if os(macOS)
                case "settings": openSettings()
                #endif
                default: break
                }
                #if os(macOS)
                if let size = DemoMode.windowSize, let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" }) {
                    window.setContentSize(size)
                    window.center()
                }
                #endif
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The clipboard's text as a handoff (#236); nothing without text.
    private func openHandoff() {
        #if !os(tvOS)
        guard let text = Platform.clipboardText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        handoff = Handoff.Request(text: text)
        #endif
    }

    #if !os(tvOS)
    /// Brings the user to the agent of a share that is not opened yet; its
    /// composer takes the share when it appears or, already on screen,
    /// from the notification.
    private func openPendingShare() {
        guard let share = PendingShare.peek(), !share.opened else { return }
        PendingShare.markOpened()
        selection = SpaceRef(hostID: share.hostID, workspaceID: share.workspaceID, paneID: share.paneID)
        NotificationCenter.default.post(name: PendingShare.arrived, object: nil)
    }
    #endif

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

    /// Without a space chosen, Mac and iPad show the overview and mark it
    /// in the sidebar; the iPhone stays on the sidebar, which a selection
    /// would leave.
    private var overviewIsPlaceholder: Bool {
        #if os(iOS)
        selection == nil && sizeClass != .compact
        #else
        selection == nil
        #endif
    }

    /// The sidebar's selection: the overview or a space.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { showingOverview || overviewIsPlaceholder ? .overview : selection.map(SidebarItem.space) },
            set: { item in
                switch item {
                case .overview:
                    selection = nil
                    showingOverview = true
                case .space(let ref):
                    selection = ref
                    showingOverview = false
                case nil:
                    selection = nil
                    showingOverview = false
                }
            }
        )
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
