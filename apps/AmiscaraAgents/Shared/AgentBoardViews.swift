import SwiftUI

/// The pieces of the widget's look, shared with the host dashboard (#278)
/// so both render the same. Only SwiftUI and `WidgetSnapshot`: this folder
/// is also built into the Watch, tvOS and extension targets.

/// The waiting count large with its label, and how many agents work.
struct WaitingHeadline<Gap: View>: View {
    let waiting: Int
    let working: Int
    /// Between the label and the working line, e.g. a `Spacer` in the widget.
    @ViewBuilder var gap: () -> Gap

    var body: some View {
        Text(waiting, format: .number)
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(waiting > 0 ? Color.orange : Color.secondary)
            .contentTransition(.numericText())
        Text(waiting == 1 ? "wartet" : "warten")
            .font(.headline)
        gap()
        if working > 0 {
            Label("\(working) arbeiten", systemImage: "circle.fill")
                .labelStyle(DotLabelStyle(color: .blue))
                .font(.caption)
        }
    }
}

extension WaitingHeadline where Gap == EmptyView {
    init(waiting: Int, working: Int) {
        self.init(waiting: waiting, working: working) { EmptyView() }
    }
}

/// One agent: state dot, place, name (and host), state label.
struct AgentSummaryRow: View {
    let agent: WidgetSnapshot.Agent
    /// Shown after the name when agents of several hosts are listed.
    let host: String?
    /// Pinned to the top in the app (#334); widgets show no pins.
    var pinned = false
    /// Steps under the parent agent for a sub-agent (#330); a sub-agent
    /// also shows its time in the state. Widgets list no sub-agents apart.
    var depth = 0

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(agent.state.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if pinned {
                        PinMark()
                    }
                    Text(agent.place).font(.caption.weight(.medium)).lineLimit(1)
                }
                Text([agent.name, host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(agent.state.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(agent.state.color)
            if depth > 0, let since = agent.since {
                TimelineView(.everyMinute) { context in
                    Text(Self.relative(since, now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    /// "vor 5 Min."; times a little ahead of this device's clock (from
    /// another device) count as now.
    static func relative(_ date: Date, now: Date) -> String {
        min(date, now).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// The mark of a pinned agent (#334), before its place.
struct PinMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Angeheftet"))
    }
}

/// "Anheften" or "Lösen" for an agent's context menu (#334).
struct PinButton: View {
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        if pinned {
            Button("Lösen", systemImage: "pin.slash", action: action)
        } else {
            Button("Anheften", systemImage: "pin", action: action)
        }
    }
}

struct DotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            configuration.title
        }
    }
}
