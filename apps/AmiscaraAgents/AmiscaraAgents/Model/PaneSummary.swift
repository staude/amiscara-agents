#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Two sentences about what happened in a pane since the last visit (#273),
/// written by the on-device model. Only on request, nothing leaves the
/// device and nothing is kept beyond the pane view.
@MainActor
@Observable
final class PaneSummary {
    enum State: Equatable {
        case offered
        case loading
        case done(String)
        case failed(String)
    }

    private(set) var state = State.offered

    /// The on-device model is there and switched on (Apple Intelligence).
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The model's context is small; the newest part is what matters.
    private static let maxCharacters = 6000

    func summarize(connection: HostConnection, paneID: String, agent: String?, visit: PaneVisits.Entry, unwrap: Bool) async {
        guard state != .loading else { return }
        state = .loading
        do {
            var text = ""
            if agent == "claude", connection.config.uploadAllowed {
                text = (try? await Self.conversation(connection: connection, paneID: paneID, since: visit.seen)) ?? ""
            }
            if text.isEmpty {
                let recent = try await connection.recentText(paneID: paneID, lines: maxHistoryLines(), unwrap: unwrap)
                text = PaneVisits.newLines(in: recent, after: visit.tail)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else {
                state = .done(String(localized: "Keine neue Ausgabe seit dem letzten Besuch."))
                return
            }
            state = .done(try await Self.summary(of: String(text.suffix(Self.maxCharacters))))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Claude Code keeps no scrollback in herdr, so its new part comes from
    /// the conversation: the entries after the last one written before
    /// `since`. Empty when there is none.
    private static func conversation(connection: HostConnection, paneID: String, since: Date) async throws -> String {
        let entries = try await connection.claudeHistory(paneID: paneID).entries
        var start = 0
        var last: Date?
        for (index, entry) in entries.enumerated() {
            // An entry without a time counts as written with the one before.
            if let date = entry.timestamp.flatMap(parseTimestamp) { last = date }
            if let last, last <= since { start = index + 1 }
        }
        return entries[start...].map { entry in
            switch entry.kind {
            case .user: "Du: \(entry.text)"
            case .assistant: "Claude: \(entry.text)"
            case .tool: "Werkzeug: \(entry.text)"
            }
        }
        .joined(separator: "\n")
    }

    /// Claude Code writes ISO 8601 in UTC with fractions of a second.
    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func summary(of text: String) async throws -> String {
        do {
            return try await respond(to: text)
        } catch LanguageModelError.contextSizeExceeded {
            return try await respond(to: String(text.suffix(text.count / 2)))
        }
    }

    private static func respond(to text: String) async throws -> String {
        let code = Bundle.main.preferredLocalizations.first ?? "de"
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "German"
        let session = LanguageModelSession(instructions: """
            You summarise new output of a terminal pane, often a coding agent at work. \
            Answer in \(language) with exactly two sentences: first whether it finished, \
            is waiting for input or ran into an error, then what changed.
            """)
        return try await session.respond(to: text).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The offer above the terminal: "Zusammenfassen", then the summary.
struct PaneSummaryBar: View {
    let connection: HostConnection
    let paneID: String
    let agent: String?
    let visit: PaneVisits.Entry
    let unwrap: Bool
    let dismiss: () -> Void
    @State private var summary = PaneSummary()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            switch summary.state {
            case .offered:
                Text("Seit dem letzten Besuch ist Neues dazugekommen.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zusammenfassen") {
                    Task {
                        await summary.summarize(connection: connection, paneID: paneID, agent: agent, visit: visit, unwrap: unwrap)
                    }
                }
            case .loading:
                Text("Fasse zusammen …").foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            case .done(let text):
                Text(text).selectableText()
                Spacer()
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).selectableText()
                Spacer()
            }
            Button("Schließen", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .help(String(localized: "Zusammenfassung schließen"))
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif
