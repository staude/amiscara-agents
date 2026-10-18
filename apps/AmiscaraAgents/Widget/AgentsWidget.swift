import SwiftUI
import WidgetKit

@main
struct AmiscaraAgentsWidgets: WidgetBundle {
    var body: some Widget {
        AgentsWidget()
    }
}

/// Agents over all hosts, waiting first (#106). The app writes the data
/// (`WidgetSnapshot`) and reloads the widget; it holds no connection itself.
struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: Provider()) { entry in
            AgentsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Wartende und arbeitende Agents auf allen Hosts.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(Entry(date: .now, snapshot: context.isPreview && snapshot.hosts.isEmpty ? .preview : snapshot))
    }

    /// One entry; the app reloads the widget when its data changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(updated: .now, hosts: [
        Host(id: UUID(), name: "work", live: true, agents: [
            Agent(paneID: "w1:p1", workspaceID: "w1", place: "enon · 1", name: "claude", state: .blocked),
            Agent(paneID: "w2:p1", workspaceID: "w2", place: "amiscara-agents · 1", name: "claude", state: .working),
            Agent(paneID: "w3:p1", workspaceID: "w3", place: "streamdeck · 1", name: "codex", state: .done),
        ]),
    ])
}

extension WidgetSnapshot.State {
    var color: Color {
        switch self {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .blocked: String(localized: "wartet")
        case .working: String(localized: "arbeitet")
        case .done: String(localized: "fertig")
        case .idle: String(localized: "bereit")
        case .unknown: String(localized: "unbekannt")
        }
    }
}

struct AgentsWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var waiting: Int { snapshot.count(.blocked) }
    private var working: Int { snapshot.count(.working) }

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: list(rows: 3)
        case .systemLarge: list(rows: 8)
        #if os(iOS)
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        #endif
        default: small
        }
    }

    // MARK: Home screen and desktop

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(waiting, format: .number)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(waiting > 0 ? Color.orange : Color.secondary)
                .contentTransition(.numericText())
            Text(waiting == 1 ? "wartet" : "warten")
                .font(.headline)
            Spacer(minLength: 0)
            if working > 0 {
                Label("\(working) arbeiten", systemImage: "circle.fill")
                    .labelStyle(DotLabelStyle(color: .blue))
                    .font(.caption)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The small widget is one tap target: the first waiting agent.
        .widgetURL(snapshot.agents.first { $0.agent.state == .blocked }.map {
            WidgetSnapshot.openURL(host: $0.host.id, workspaceID: $0.agent.workspaceID, paneID: $0.agent.paneID)
        })
    }

    private func list(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                if waiting > 0 {
                    Text("\(waiting) wartet").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            if snapshot.agents.isEmpty {
                Spacer()
                Text(snapshot.hosts.isEmpty ? "Noch keine Daten. Öffnen Sie die App einmal." : "Keine Agents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(snapshot.agents.prefix(rows), id: \.agent.id) { host, agent in
                    Link(destination: WidgetSnapshot.openURL(host: host.id, workspaceID: agent.workspaceID, paneID: agent.paneID)) {
                        row(agent, host: snapshot.hosts.count > 1 ? host.name : nil)
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ agent: WidgetSnapshot.Agent, host: String?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(agent.state.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.place).font(.caption.weight(.medium)).lineLimit(1)
                Text([agent.name, host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(agent.state.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(agent.state.color)
        }
    }

    /// How old the data is: on iOS it only changes while the app runs.
    private var footer: some View {
        Group {
            if snapshot.updated == .distantPast {
                Text("Keine Daten")
            } else {
                Text("Stand \(snapshot.updated, style: .relative)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    // MARK: Lock screen

    #if os(iOS)
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(waiting, format: .number).font(.title2.weight(.bold))
                Text("wartet").font(.caption2)
            }
        }
        .widgetURL(snapshot.agents.first { $0.agent.state == .blocked }.map {
            WidgetSnapshot.openURL(host: $0.host.id, workspaceID: $0.agent.workspaceID, paneID: $0.agent.paneID)
        })
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(waiting) wartet · \(working) arbeiten").font(.headline)
            if let first = snapshot.agents.first(where: { $0.agent.state == .blocked }) {
                Text(first.agent.place).font(.caption).lineLimit(1)
            }
            Text("Stand \(snapshot.updated, style: .relative)").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Text(waiting > 0 ? "\(waiting) Agents warten" : "Keine Agents warten")
    }
    #endif
}

private struct DotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            configuration.title
        }
    }
}

#Preview(as: .systemMedium) {
    AgentsWidget()
} timeline: {
    Entry(date: .now, snapshot: .preview)
}
