#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action button controls (#227).

/// "Wartende Agents": how many wait; opens the first of them.
struct WaitingAgentsControl: ControlWidget {
    static let kind = WaitingControlKind.waiting

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetButton(action: OpenURLIntent(value.url)) {
                Label {
                    Text(value.waiting == 0 ? "Kein Agent wartet" : "\(value.waiting) warten")
                } icon: {
                    Image(systemName: value.waiting > 0 ? "hand.raised.fill" : "terminal")
                }
            }
        }
        .displayName("Wartende Agents")
        .description("Zeigt, wie viele Agents warten, und öffnet den ersten.")
    }

    struct Value {
        let waiting: Int
        let url: URL
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value { Value(waiting: 1, url: WidgetSnapshot.appURL) }

        func currentValue() async throws -> Value {
            // With the Mac's boards from iCloud, like the widget, so it is
            // right while the app does not run.
            let local = WidgetSnapshot.load()
            let keys = local.hosts.compactMap(\.hostKey)
            let boards = (try? await CloudBoard.fetch(hostKeys: keys)) ?? []
            let snapshot = local.merging(boards)
            let first = snapshot.agents.first { $0.agent.state == .blocked }
            let url = first.map {
                WidgetSnapshot.openURL(host: $0.host.id, workspaceID: $0.agent.workspaceID, paneID: $0.agent.paneID)
            } ?? WidgetSnapshot.appURL
            return Value(waiting: snapshot.count(.blocked), url: url)
        }
    }
}

/// "Diktat an letzten Agent": opens the agent the last prompt went to with
/// dictation running.
struct DictateControl: ControlWidget {
    static let kind = WaitingControlKind.dictate

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { url in
            ControlWidgetButton(action: OpenURLIntent(url)) {
                Label("Diktat an letzten Agent", systemImage: "mic.fill")
            }
        }
        .displayName("Diktat an letzten Agent")
        .description("Öffnet den Agent, an den zuletzt ein Prompt ging, und startet das Diktat.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: URL { WidgetSnapshot.appURL }

        func currentValue() async throws -> URL {
            guard let last = WidgetSnapshot.lastAgent() else { return WidgetSnapshot.appURL }
            return WidgetSnapshot.openURL(host: last.host, workspaceID: last.workspaceID, paneID: last.paneID, dictate: true)
        }
    }
}
#endif
