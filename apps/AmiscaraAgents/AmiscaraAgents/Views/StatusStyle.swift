import SwiftUI

extension AgentState {
    /// Board order: blocked first, as in the core.
    var urgency: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        case .unknown: 4
        }
    }

    var color: Color {
        switch self {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle: .secondary
        case .unknown: .gray
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

struct StatusDot: View {
    /// `nil` for a plain shell.
    let state: AgentState?

    var body: some View {
        Circle()
            .fill(state?.color ?? Color.clear)
            .strokeBorder(state == nil ? Color.secondary : Color.clear, lineWidth: 1)
            .frame(width: 8, height: 8)
            .accessibilityLabel(state?.label ?? String(localized: "Shell"))
    }
}
