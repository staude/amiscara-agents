import SwiftUI
import WidgetKit

@main
struct AmiscaraAgentsWatchWidgets: WidgetBundle {
    var body: some Widget {
        AgentsComplication()
    }
}

/// Complications and Smart Stack of the Watch (#158): how many agents wait
/// and who first. The Watch app leaves its snapshot in the App Group; the
/// widget adds the Mac's boards from iCloud itself, so it stays current
/// while the app does not run.
struct AgentsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: Provider()) { entry in
            ComplicationView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Wartende Agents auf allen Hosts.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    /// Raises the widget in the Smart Stack while an agent waits.
    var relevance: TimelineEntryRelevance? {
        let waiting = snapshot.count(.blocked)
        return TimelineEntryRelevance(score: waiting > 0 ? Float(min(waiting, 5)) * 20 : 0)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(Entry(date: .now, snapshot: context.isPreview && snapshot.hosts.isEmpty ? .preview : snapshot))
    }

    /// One entry from the App Group snapshot and the boards; the Watch app
    /// reloads the widget when either changes (also on a board push), and
    /// WidgetKit asks again after a while within its budget.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // WidgetKit calls the handler once from any thread; it is not marked
        // `Sendable`.
        nonisolated(unsafe) let completion = completion
        Task {
            let snapshot = WidgetSnapshot.load()
            let keys = snapshot.hosts.compactMap(\.hostKey)
            let boards = (try? await CloudBoard.fetch(hostKeys: keys)) ?? []
            let entry = Entry(date: .now, snapshot: snapshot.merging(boards))
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(updated: .now, hosts: [
        Host(id: UUID(), name: "work", live: true, agents: [
            Agent(paneID: "w1:p1", workspaceID: "w1", place: "enon · 1", name: "claude", state: .blocked),
            Agent(paneID: "w2:p1", workspaceID: "w2", place: "amiscara-agents · 1", name: "claude", state: .working),
        ]),
    ])
}

struct ComplicationView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var waiting: Int { snapshot.count(.blocked) }
    private var first: (host: WidgetSnapshot.Host, agent: WidgetSnapshot.Agent)? {
        snapshot.agents.first { $0.agent.state == .blocked }
    }

    var body: some View {
        content
            // Opens the first waiting agent in the Watch app.
            .widgetURL(first.map {
                WidgetSnapshot.openURL(host: $0.host.id, workspaceID: $0.agent.workspaceID, paneID: $0.agent.paneID)
            })
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryCorner: corner
        default: inline
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(waiting, format: .number)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(waiting > 0 ? Color.orange : Color.secondary)
                    .widgetAccentable()
                Text("wartet").font(.caption2)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(waiting == 0 ? "Keiner wartet" : "\(waiting) wartet")
                .font(.headline)
                .foregroundStyle(waiting > 0 ? Color.orange : Color.primary)
                .widgetAccentable()
            if let first {
                Text(first.agent.place).font(.caption).lineLimit(1)
                Text(snapshot.hosts.count > 1 ? "\(first.agent.name) · \(first.host.name)" : first.agent.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                let working = snapshot.count(.working)
                Text(working > 0 ? "\(working) arbeiten" : "Keine Agents aktiv")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var corner: some View {
        Image(systemName: waiting > 0 ? "exclamationmark.bubble.fill" : "checkmark.bubble")
            .font(.title3)
            .widgetAccentable()
            .widgetLabel {
                Text(waiting > 0 ? "\(waiting) wartet" : "Agents")
            }
    }

    private var inline: some View {
        Text(waiting > 0 ? "\(waiting) Agents warten" : "Keine Agents warten")
    }
}

#Preview(as: .accessoryRectangular) {
    AgentsComplication()
} timeline: {
    Entry(date: .now, snapshot: .preview)
}
