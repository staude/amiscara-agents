#if os(macOS)
import AppKit
import SwiftUI

/// The menu bar item: how many agents wait, over all hosts, and a menu to
/// jump to one of them. It lives as long as the app, so it also opens the
/// main window when that is closed.
struct MenuBarMenu: View {
    let store: HostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = store.waitingAgents
        if AppLock.shared.isEnabled && AppLock.shared.isLocked {
            // No agent names or panes while the app lock holds (#232).
            Text("Amiscara Agents ist gesperrt")
        } else if waiting.isEmpty {
            Text("Kein Agent wartet")
        } else {
            // Host names only help when there is more than one host.
            let showHosts = Set(waiting.map(\.connection.id)).count > 1
            ForEach(waiting, id: \.agent.paneId) { entry in
                Button {
                    // With the window open, front it here: it takes the
                    // request at once and the label may never see it. With
                    // none open, the label opens one.
                    MainWindow.bringToFront()
                    store.notifier.openRequest = SpaceRef(
                        hostID: entry.connection.id,
                        workspaceID: entry.agent.workspaceId,
                        paneID: entry.agent.paneId
                    )
                } label: {
                    Text(entry.agent.agent.isEmpty ? String(localized: "Agent") : entry.agent.agent)
                    Text(showHosts
                        ? "\(entry.connection.config.name) · \(entry.agent.spacePlace) · Tab \(entry.agent.tabLabel)"
                        : "\(entry.agent.spacePlace) · Tab \(entry.agent.tabLabel)")
                }
            }
        }
        Divider()
        Button("Amiscara Agents öffnen") {
            if !MainWindow.bringToFront() {
                openWindow(id: MainWindow.id)
                NSApp.activate()
            }
        }
    }
}

/// The menu bar icon with the number of waiting agents. Unlike the menu, the
/// label is always on screen, so it also opens the main window when a
/// notification or menu entry asks for a pane while no window is open.
struct MenuBarLabel: View {
    let store: HostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = store.waitingAgents.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "bell.badge" : "terminal")
            if count > 0 {
                Text("\(count)")
            }
        }
        .accessibilityLabel(count > 0
            ? String(localized: "\(count) Agents warten")
            : String(localized: "Amiscara Agents"))
        .onChange(of: store.notifier.openRequest) { _, request in
            if request != nil { show() }
        }
    }

    private func show() {
        if !MainWindow.bringToFront() {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}

/// The main window on the Mac.
@MainActor
enum MainWindow {
    nonisolated static let id = "main"

    private static var window: NSWindow? {
        // The app has no other windows that can become main; the menu bar
        // item's and the menu's cannot. Closed windows can linger invisible
        // and do not count.
        NSApp.windows.first { window in
            window.canBecomeMain && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Activates the app and fronts the main window; false when none is open.
    @discardableResult
    static func bringToFront() -> Bool {
        // While the app lock holds, its cover instead (#232).
        if AppLockCurtain.shared.bringToFront() { return true }
        guard let window else { return false }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
#endif
