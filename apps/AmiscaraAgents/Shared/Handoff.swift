import Foundation

#if !os(tvOS)
/// A handoff from another AI tool (#236): text planned in Claude, ChatGPT
/// or elsewhere goes to an agent as a Markdown file in its composer, with a
/// prompt that tells the agent to read it. It arrives by share sheet, from
/// the clipboard or as `amiscara-agents://prompt?text=…`; the composer
/// uploads the file and puts its path on its own line after the prompt.
enum Handoff {
    /// Longer text is not handed over, in characters.
    static let maxLength = 1_000_000

    private static let promptKey = "handoffPrompt"

    static var defaultPrompt: String {
        String(localized: "Lies die Übergabe in dieser Datei und setze sie um:")
    }

    /// The prompt that goes with the file; the user's last one, kept in the
    /// App Group so the share extension and the app agree. Empty means the
    /// default.
    static var prompt: String {
        get {
            let saved = UserDefaults(suiteName: WidgetSnapshot.appGroup)?.string(forKey: promptKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return saved.isEmpty ? defaultPrompt : saved
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroup)
            if trimmed.isEmpty || trimmed == defaultPrompt {
                defaults?.removeObject(forKey: promptKey)
            } else {
                defaults?.set(trimmed, forKey: promptKey)
            }
        }
    }

    /// `handoff-2026-10-26-0912.md`; the core puts `file-<time>-` before it.
    static func fileName(at date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmm"
        return "handoff-\(format.string(from: date)).md"
    }

    /// Whether the share extension offers the text as a file at first:
    /// long text, or a Markdown file. Short text goes in as the prompt.
    static func suggestsFile(text: String, isMarkdownFile: Bool) -> Bool {
        text.count >= 2000 || isMarkdownFile
    }

    /// What an `amiscara-agents://prompt` link or the clipboard hands over.
    struct Request: Identifiable {
        let id = UUID()
        let text: String
        /// The host's id or name, as the link gives it.
        var host: String?
        /// herdr's pane id.
        var pane: String?
        /// From a link: any page or app may have written the text, so the
        /// sheet says where it came from.
        var fromLink = false

        /// Whether `host` names this host: its id, or its name ignoring case.
        func names(hostID: UUID, name: String) -> Bool {
            guard let host else { return false }
            if let id = UUID(uuidString: host) { return id == hostID }
            return host.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The link's query; `+` is a space as in form encoding, which many
    /// tools write (`URLSearchParams`, Python's `urlencode`).
    private static func queryItems(_ url: URL) -> [URLQueryItem]? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.map { item in
            URLQueryItem(
                name: item.name,
                value: item.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            )
        }
    }

    /// `amiscara-agents://prompt?text=…&host=…&pane=…`; `nil` for any other
    /// link and for one without text or with too much of it.
    static func parsePromptURL(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == "amiscara-agents", url.host()?.lowercased() == "prompt",
              let items = queryItems(url),
              let text = items.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= maxLength
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Request(text: text, host: value("host"), pane: value("pane"), fromLink: true)
    }
}
#endif
