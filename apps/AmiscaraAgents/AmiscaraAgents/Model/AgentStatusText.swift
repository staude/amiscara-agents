import Foundation

/// The answer to "Was macht der Agent?" (#275): status, since when, and
/// the last lines of the screen, as one text to speak and to show.
enum AgentStatusText {
    /// Where the answer comes from: this device's own connection, or the
    /// board the Mac wrote at `updated`.
    enum Source: Equatable {
        case live
        case mac(updated: Date)
    }

    /// `since` is when the state began, `nil` when nobody saw it begin.
    /// The duration follows "schon", not "seit": the format style has no
    /// dative ("seit 2 Tage"). `linesMissingOffline` says why no lines come.
    static func text(
        name: String,
        space: String,
        status: String,
        since: Date?,
        now: Date,
        lines: [String],
        source: Source,
        linesMissingOffline: Bool
    ) -> String {
        let who = space.isEmpty ? name : String(localized: "\(name) in \(space)")
        var parts: [String] = []
        if case .mac(let updated) = source {
            if let age = duration(from: updated, to: now) {
                parts.append(String(localized: "Laut Mac (Stand vor \(age)):"))
            } else {
                parts.append(String(localized: "Laut Mac (Stand gerade eben):"))
            }
        }
        switch (since, since.flatMap { duration(from: $0, to: now) }) {
        case (_, let duration?):
            parts.append(String(localized: "\(who): \(status), schon \(duration)."))
        case (.some, nil):
            parts.append(String(localized: "\(who): \(status), gerade eben gewechselt."))
        default:
            parts.append(String(localized: "\(who): \(status)."))
        }
        if !lines.isEmpty {
            parts.append(String(localized: "Auf dem Bildschirm: \(lines.joined(separator: " / "))"))
        } else if linesMissingOffline {
            parts.append(String(localized: "Bildschirmzeilen gibt es ohne Verbindung nur für wartende Agents."))
        }
        return parts.joined(separator: " ")
    }

    /// Neither the host nor the Mac's board knows the agent right now.
    static func noData(name: String) -> String {
        String(localized: "Zu \(name) liegen gerade keine Daten vor. Der Host ist nicht erreichbar oder der Agent läuft nicht mehr.")
    }

    /// Days, hours and minutes from `start` to `end`; `nil` under a minute.
    private static func duration(from start: Date, to end: Date) -> String? {
        guard end.timeIntervalSince(start) >= 60 else { return nil }
        return (start..<end).formatted(.components(style: .wide, fields: [.day, .hour, .minute]))
    }
}
