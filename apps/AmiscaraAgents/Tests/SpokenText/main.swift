// Checks the text for reading aloud (#297) without the UI: code blocks and
// links are named, heading, list and quote marks dropped, inline Markdown
// made plain, German and English recognized, empty stays empty. Built by
// scripts/spoken-text-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

let code = SpokenText.make(from: "Vorher.\n\n```swift\nlet x = 1\n```\n\nNachher.")
check(code.text == "Vorher.\n\nCodeblock ausgelassen.\n\nNachher.", "code block named, not read: \(code.text)")
check(!SpokenText.make(from: "~~~\nrm -rf /\n~~~").text.contains("rm"), "tilde fence skipped too")

let link = SpokenText.make(from: "Siehe https://example.com/a?b=1 und <https://x.org>.").text
check(link == "Siehe Link und Link.", "bare URLs become Link: \(link)")
let markdownLink = SpokenText.make(from: "Die [Doku](https://example.com) erklärt es.").text
check(markdownLink == "Die Doku erklärt es.", "Markdown link keeps its text: \(markdownLink)")

let list = SpokenText.make(from: "## Ergebnis\n- **eins**\n* `zwei`\n> drei\n---\n1. vier").text
check(list == "Ergebnis\neins\nzwei\ndrei\n\n1. vier", "marks dropped, inline Markdown plain: \(list)")

let german = SpokenText.make(from: "Ich habe die Tests ausgeführt, und alle sind grün. Soll ich den Branch pushen?")
check(german.language == "de", "German recognized: \(german.language)")
let english = SpokenText.make(from: "I ran the tests and they all pass. Should I push the branch now?")
check(english.language == "en", "English recognized: \(english.language)")

let englishCode = SpokenText.make(from: "Here is the fix for the failing test:\n\n```\nlet x = 1\n```\n\nSee https://example.com for details.")
check(englishCode.language == "en", "language ignores the named parts: \(englishCode.language)")
check(!englishCode.text.contains("\u{E000}") && !englishCode.text.contains("\u{E001}"), "no marks left: \(englishCode.text)")

let empty = SpokenText.make(from: "  \n\n ")
check(empty.text.isEmpty, "empty stays empty")
check(!empty.language.isEmpty, "empty still has a language")

if failures > 0 { exit(1) }
print("spoken-text: ok")
