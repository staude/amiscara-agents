import SwiftUI
import WidgetKit

@main
struct AmiscaraAgentsWidgets: WidgetBundle {
    var body: some Widget {
        AgentsWidget()
        #if os(iOS)
        AgentsLiveActivity()
        WaitingAgentsControl()
        DictateControl()
        #endif
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
        // The extra large sizes are for the iPad and the inner display of
        // the iPhone Duo (#215); the outer one takes the iPhone sizes.
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .systemExtraLargePortrait,
         .accessoryCircular, .accessoryRectangular, .accessoryInline]
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

    /// One entry; the app reloads the widget when its data changes. On iOS
    /// the widget also takes the boards the Mac leaves in iCloud (#156) and
    /// asks again after a while, so it stays current when the app does not
    /// run.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        #if os(iOS)
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
        #else
        completion(Timeline(entries: [Entry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
        #endif
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(updated: .now, hosts: [
        Host(id: UUID(), name: "Mac Studio", live: true, agents: [
            Agent(paneID: "w1:p1", workspaceID: "w1", place: "API (Shop) · 1", name: "claude", state: .blocked),
            Agent(paneID: "w2:p1", workspaceID: "w2", place: "Web (Shop) · 1", name: "claude", state: .working),
            Agent(paneID: "w3:p1", workspaceID: "w3", place: "Blog · 1", name: "codex", state: .done),
        ]),
    ])
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
        case .systemExtraLarge: list(rows: 16, columns: 2)
        case .systemExtraLargePortrait: list(rows: 16)
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
            WaitingHeadline(waiting: waiting, working: working) {
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The small widget is one tap target: the first waiting agent.
        .widgetURL(snapshot.agents.first { $0.agent.state == .blocked }.map {
            WidgetSnapshot.openURL(host: $0.host.id, workspaceID: $0.agent.workspaceID, paneID: $0.agent.paneID)
        })
    }

    /// Up to `rows` agents, filled column by column.
    private func list(rows: Int, columns: Int = 1) -> some View {
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
                let perColumn = (rows + columns - 1) / columns
                let shown = Array(snapshot.agents.prefix(rows))
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<columns, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(shown.dropFirst(column * perColumn).prefix(perColumn), id: \.agent.id) { host, agent in
                                Link(destination: WidgetSnapshot.openURL(host: host.id, workspaceID: agent.workspaceID, paneID: agent.paneID)) {
                                    AgentSummaryRow(agent: agent, host: snapshot.hosts.count > 1 ? host.name : nil)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How old the data is: on iOS it only changes while the app runs. The
    /// medium widget adds today's tokens per host when the app sends them
    /// (#302, "Tageskosten im Widget").
    private var footer: some View {
        HStack(spacing: 8) {
            if snapshot.updated == .distantPast {
                Text("Keine Daten")
            } else {
                Text("Stand \(snapshot.updated, style: .relative)")
            }
            if family == .systemMedium {
                let hosts = snapshot.hosts.filter { $0.usageToday != nil }
                ForEach(hosts) { host in
                    if let usage = host.usageToday {
                        Text(hosts.count > 1 || snapshot.hosts.count > 1 ? "\(host.name): \(usage.todayText)" : usage.todayText)
                    }
                }
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

#Preview(as: .systemMedium) {
    AgentsWidget()
} timeline: {
    Entry(date: .now, snapshot: .preview)
}
