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

    var body: some View {
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
