import Foundation
import NaturalLanguage

/// An assistant message from the Claude conversation as text for the speech
/// synthesizer (#297): code blocks and links are named instead of read,
/// heading and list marks dropped, the rest of the Markdown made plain.
enum SpokenText {
    /// The text to speak and its language (BCP 47, e.g. `de`), from the
    /// text itself, else the app's language. Empty Markdown gives empty text.
    static func make(from markdown: String) -> (text: String, language: String) {
        var lines: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inCode { lines.append(String(localized: "Codeblock ausgelassen.")) }
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
        let text = inline
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, language(of: text))
    }

    /// A line without its heading, list or quote mark; a rule is dropped.
    private static func plainLine(_ line: String) -> String {
        if line.count >= 3, line.allSatisfy({ "-*_".contains($0) }) { return "" }
        return line.replacing(#/^(#{1,6}|[-*+>])\s+/#, with: "")
    }

    /// Bare URLs (also `<…>`) become "Link"; the text of a Markdown link
    /// stays, its target goes with the Markdown.
    private static func withoutURLs(_ text: String) -> String {
        let link = String(localized: "Link")
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
