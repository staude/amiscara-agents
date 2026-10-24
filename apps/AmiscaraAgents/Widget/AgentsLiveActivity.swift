#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Working and waiting agents on the Lock Screen and in the Dynamic Island
/// (#224). A waiting agent gets the answer buttons of its notification.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let first = context.state.agents.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let first {
                        Label(first.name, systemImage: "circle.fill")
                            .labelStyle(DotLabel(color: first.state.color))
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let first {
                        Text(first.state.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(first.state.color)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let first {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(first.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let line = first.line, !line.isEmpty {
                                Text(line).font(.caption.monospaced()).lineLimit(2)
                                    .privacySensitive()
                            }
                            if first.state == .blocked {
                                AnswerButtons(entry: first)
                            }
                            if context.state.agents.count > 1 {
                                Text(others(context.state))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.waiting > 0 ? "hand.raised.fill" : "terminal")
                    .foregroundStyle(context.state.waiting > 0 ? Color.orange : Color.blue)
            } compactTrailing: {
                Text(context.state.waiting > 0 ? "\(context.state.waiting)" : "\(context.state.working)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.waiting > 0 ? Color.orange : Color.blue)
            } minimal: {
                Image(systemName: context.state.waiting > 0 ? "hand.raised.fill" : "terminal")
                    .foregroundStyle(context.state.waiting > 0 ? Color.orange : Color.blue)
            }
            .widgetURL(first.map { WidgetSnapshot.openURL(host: $0.hostID, workspaceID: $0.workspaceID, paneID: $0.paneID) })
        }
    }

    private func others(_ state: AgentsActivityAttributes.ContentState) -> String {
        let more = state.waiting + state.working - 1
        return more == 1 ? String(localized: "und 1 weiterer Agent") : String(localized: "und \(more) weitere Agents")
    }
}

private struct LockScreenView: View {
    let state: AgentsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                if state.waiting > 0 {
                    Text("\(state.waiting) wartet").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                if state.working > 0 {
                    Text("\(state.working) arbeiten").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            ForEach(state.agents) { entry in
                Link(destination: WidgetSnapshot.openURL(host: entry.hostID, workspaceID: entry.workspaceID, paneID: entry.paneID)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(entry.state.color).frame(width: 8, height: 8)
                            Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(entry.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(entry.state.label).font(.caption).foregroundStyle(entry.state.color)
                        }
                        if let line = entry.line, !line.isEmpty {
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                // Screen content: hidden on a locked device
                                // when the user hides sensitive content.
                                .privacySensitive()
                        }
                    }
                }
                if entry.state == .blocked {
                    AnswerButtons(entry: entry)
                }
            }
        }
    }
}

/// The notification's answers: options 1 to 3, Enter and Esc.
private struct AnswerButtons: View {
    let entry: AgentsActivityAttributes.Entry

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AgentNotification.answers, id: \.key) { answer in
                Button(intent: AnswerAgentIntent(hostID: entry.hostID, paneID: entry.paneID, key: answer.key)) {
                    Text(answer.title)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(answer.key == "enter" ? .orange : .gray)
            }
        }
    }
}

private struct DotLabel: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            configuration.title
        }
    }
}
#endif
