import Foundation
import NaturalLanguage

/// An assistant message from the Claude conversation as text for the speech
/// synthesizer (#297): code blocks and links are named instead of read,
/// heading and list marks dropped, the rest of the Markdown made plain.
enum SpokenText {
    /// Stand for the named parts until the language is known.
    private static let codeMark = "\u{E000}"
    private static let linkMark = "\u{E001}"

    /// The text to speak and its language (BCP 47, e.g. `de`), from the
    /// text itself, else the app's language; the named parts are in that
    /// language too. Empty Markdown gives empty text.
    static func make(from markdown: String) -> (text: String, language: String) {
        var lines: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inCode { lines.append(codeMark) }
                inCode.toggle()
                continue
            }
            if !inCode { lines.append(plainLine(trimmed)) }
        }
        let joined = withoutURLs(lines.joined(separator: "\n"))
        let inline = (try? AttributedString(
            markdown: joined,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map { String($0.characters) } ?? joined
        let marked = inline
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = language(of: marked.replacing(codeMark, with: "").replacing(linkMark, with: ""))
        let text = marked
            .replacing(codeMark, with: phrase("Codeblock ausgelassen.", String(localized: "Codeblock ausgelassen."), in: language))
            .replacing(linkMark, with: phrase("Link", String(localized: "Link"), in: language))
        return (text, language)
    }

    /// `key` in `language` where the app has that language, else `inApp`.
    /// The keys are the German source text.
    private static func phrase(_ key: String, _ inApp: String, in language: String) -> String {
        if language == "de" { return key }
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return inApp }
        return bundle.localizedString(forKey: key, value: inApp, table: nil)
    }

    /// A line without its heading, list or quote mark; a rule is dropped.
    private static func plainLine(_ line: String) -> String {
        if line.count >= 3, line.allSatisfy({ "-*_".contains($0) }) { return "" }
        return line.replacing(#/^(#{1,6}|[-*+>])\s+/#, with: "")
    }

    /// Bare URLs (also `<…>`) become "Link"; the text of a Markdown link
    /// stays, its target goes with the Markdown.
    private static func withoutURLs(_ text: String) -> String {
        let link = linkMark
        return text
            .replacing(#/<https?:\/\/[^\s>]+>/#, with: link)
            .replacing(#/(\]\()?https?:\/\/[^\s)>\]]+/#) { match in
                match.output.1 == nil ? link : String(match.output.0)
            }
    }

    private static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage, language != .undetermined {
            return language.rawValue
        }
        return Bundle.main.preferredLocalizations.first ?? "de"
    }
}
