import SwiftUI

/// Status colors and labels as in the app, for the widgets and the Watch.
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
