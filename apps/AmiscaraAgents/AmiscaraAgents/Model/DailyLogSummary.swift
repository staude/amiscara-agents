#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import Observation

/// A few sentences about a host's day (#301), written by the on-device
/// model from the entries shown. Only on request; nothing leaves the
/// device and nothing is kept beyond the sheet.
@MainActor
@Observable
final class DailyLogSummary {
    enum State: Equatable {
        case offered
        case loading
        case done(String)
        case failed(String)
    }

    private(set) var state = State.offered

    /// The model's context is small; the day's start is kept, the rest cut.
    private static let maxCharacters = 6000

    /// Back to the offer, e.g. for another day.
    func reset() {
        state = .offered
    }

    func summarize(_ items: [DailyItem]) async {
        guard state != .loading else { return }
        state = .loading
        do {
            let text = String(Self.timeline(items).prefix(Self.maxCharacters))
            state = .done(try await Self.summary(of: text))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// One line per entry: `HH:mm place – kind: text`.
    static func timeline(_ items: [DailyItem]) -> String {
        items.map { item in
            let time = Date(timeIntervalSince1970: TimeInterval(item.timeMs) / 1000)
                .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            let kind = switch item.kind {
            case .prompt: "Auftrag"
            case .done: "Fertig"
            case .commit: "Commit"
            }
            return "\(time) \(item.place) – \(kind): \(item.text)"
        }
        .joined(separator: "\n")
    }

    private static func summary(of text: String) async throws -> String {
        do {
            return try await respond(to: text)
        } catch LanguageModelError.contextSizeExceeded {
            return try await respond(to: String(text.prefix(text.count / 2)))
        }
    }

    private static func respond(to text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You summarise a day on a developer's machine from a timeline: tasks given to \
            coding agents (Auftrag), turns they finished (Fertig) and commits, each with \
            time and space. Answer in \(PaneSummary.answerLanguage) with three to five \
            sentences: what was worked on in which space, what got finished, what is still open.
            """)
        return try await session.respond(to: text).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
