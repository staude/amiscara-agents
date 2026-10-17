import SwiftUI

/// A space as herdr shows it: tabs along the top, then the selected pane.
/// A split tab gets a pane picker under the tab bar.
struct WorkspaceDetailView: View {
    @Environment(HostStore.self) private var store
    let selection: SpaceRef?
    @State private var tabID: String?
    @State private var paneID: String?

    var body: some View {
        Group {
            if let selection,
               let connection = store.connection(for: selection.hostID),
               let workspace = connection.update?.workspaces.first(where: { $0.workspaceId == selection.workspaceID }) {
                VStack(spacing: 0) {
                    tabBar(workspace)
                    if let tab = currentTab(workspace), tab.panes.count > 1 {
                        panePicker(tab)
                    }
                    Divider()
                    PaneDetailView(selection: paneID.map { PaneRef(hostID: connection.id, paneID: $0) })
                }
                .navigationTitle(workspace.worktreeName ?? workspace.label)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                ContentUnavailableView(
                    "Kein Space gewählt",
                    systemImage: "square.split.2x1",
                    description: Text("Wählen Sie links einen Space oder einen Agent.")
                )
            }
        }
        .onChange(of: selection, initial: true) { _, selection in
            focus(on: selection)
        }
    }

    private func currentTab(_ workspace: WorkspaceItem) -> TabItem? {
        workspace.tabs.first { $0.tabId == tabID }
    }

    private func tabBar(_ workspace: WorkspaceItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs, id: \.tabId) { tab in
                    Button {
                        select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.label)
                            if tab.agentState != .idle && tab.agentState != .unknown {
                                StatusDot(state: tab.agentState)
                            }
                        }
                        .font(.callout.monospaced())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            tab.tabId == tabID ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func panePicker(_ tab: TabItem) -> some View {
        Picker("Pane", selection: Binding(get: { paneID ?? "" }, set: { paneID = $0 })) {
            ForEach(tab.panes, id: \.paneId) { pane in
                Text(pane.agent ?? (pane.title.isEmpty ? pane.paneId : pane.title)).tag(pane.paneId)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func select(_ tab: TabItem) {
        tabID = tab.tabId
        paneID = (tab.panes.first { $0.focused } ?? tab.panes.first)?.paneId
    }

    /// An agent picks its own tab and pane; a space opens on herdr's active tab.
    private func focus(on selection: SpaceRef?) {
        guard let selection,
              let workspace = store.connection(for: selection.hostID)?.update?.workspaces
                .first(where: { $0.workspaceId == selection.workspaceID })
        else {
            tabID = nil
            paneID = nil
            return
        }
        if let pane = selection.paneID,
           let tab = workspace.tabs.first(where: { $0.panes.contains { $0.paneId == pane } }) {
            tabID = tab.tabId
            paneID = pane
        } else if let tab = workspace.tabs.first(where: { $0.tabId == workspace.activeTabId }) ?? workspace.tabs.first {
            select(tab)
        }
    }
}
