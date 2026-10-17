import SwiftUI

/// Hosts, their workspaces, tabs and panes.
struct SidebarView: View {
    @Environment(HostStore.self) private var store
    @Binding var selection: PaneRef?
    @Binding var editing: HostConfig?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.connections) { connection in
                Section {
                    hostContent(connection)
                } header: {
                    HostHeader(connection: connection)
                        .contextMenu {
                            Button("Bearbeiten …") { editing = connection.config }
                            Button("Neu verbinden") { connection.start() }
                            Divider()
                            Button("Entfernen", role: .destructive) {
                                store.remove(connection.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AddHostButton(editing: $editing)
            }
        }
        .overlay {
            if store.connections.isEmpty {
                NoHostsView(editing: $editing)
            }
        }
    }

    @ViewBuilder
    private func hostContent(_ connection: HostConnection) -> some View {
        if let workspaces = connection.update?.workspaces {
            ForEach(workspaces, id: \.workspaceId) { workspace in
                DisclosureGroup {
                    ForEach(workspace.tabs, id: \.tabId) { tab in
                        ForEach(tab.panes, id: \.paneId) { pane in
                            PaneRow(pane: pane, tabLabel: workspace.tabs.count > 1 ? tab.label : nil)
                                .tag(PaneRef(hostID: connection.id, paneID: pane.paneId))
                        }
                    }
                } label: {
                    Label {
                        Text(workspace.label)
                    } icon: {
                        StatusDot(state: workspace.agentState)
                    }
                }
            }
        }
    }
}

private struct HostHeader: View {
    let connection: HostConnection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.config.kind == .local ? "desktopcomputer" : "network")
            Text(connection.config.name)
            Spacer()
            HostStatusLabel(connection: connection)
        }
    }
}

private struct PaneRow: View {
    let pane: PaneItem
    let tabLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: pane.agent == nil ? nil : pane.agentState)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title.isEmpty ? pane.paneId : pane.title)
                    .lineLimit(1)
                Text([pane.agent ?? String(localized: "Shell"), tabLabel.map { "Tab \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact connection state for a host.
struct HostStatusLabel: View {
    let connection: HostConnection

    var body: some View {
        if let error = connection.startError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(error)
        } else {
            switch connection.status {
            case .live:
                EmptyView()
            case .connecting, nil:
                ProgressView().controlSize(.mini)
            case .retrying(let attempt, let error):
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .help("Versuch \(attempt): \(error)")
            case .hostKeyUnknown, .hostKeyChanged:
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                    .help("Host-Key muss bestätigt werden")
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
    }
}
