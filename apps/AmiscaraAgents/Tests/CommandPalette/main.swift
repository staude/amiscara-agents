// Checks the switcher's commands (#346) without the UI: the `>` prefix,
// how entries and commands are combined, the shortcut glyphs and the
// matching. Built by scripts/command-palette-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// MARK: PaletteQuery.parse

check(PaletteQuery.parse(">") == PaletteQuery(text: "", commandsOnly: true), "> alone asks for all commands")
check(PaletteQuery.parse("> neu") == PaletteQuery(text: " neu", commandsOnly: true), "> keeps the words after it")
check(PaletteQuery.parse(" >x") == PaletteQuery(text: "x", commandsOnly: true), "leading spaces before > are dropped")
check(PaletteQuery.parse("neu") == PaletteQuery(text: "neu", commandsOnly: false), "without > it is a normal query")
check(PaletteQuery.parse("a>b") == PaletteQuery(text: "a>b", commandsOnly: false), "> inside the text is no prefix")
check(PaletteQuery.parse(">").isEmpty, "> alone has no words")
check(!PaletteQuery.parse("> neu").isEmpty, "> neu has a word")

// MARK: PaletteResults.combine

struct Item { let name: String }

let entries = [Item(name: "Dorfkino"), Item(name: "Neuland")]
let commands = [Item(name: "Neuer Tab"), Item(name: "Tab schließen"), Item(name: "Dateien")]

func names(_ results: [PaletteResult<Item, Item>]) -> [String] {
    results.map { result in
        switch result {
        case .entry(let item): "e:\(item.name)"
        case .command(let item): "c:\(item.name)"
        }
    }
}

func combine(_ query: String) -> [String] {
    names(PaletteResults.combine(
        entries: entries,
        entryFields: { [$0.name] },
        commands: commands,
        commandFields: { [$0.name] },
        query: PaletteQuery.parse(query)
    ))
}

check(combine("") == ["e:Dorfkino", "e:Neuland"], "empty query: entries only: \(combine(""))")
check(combine("   ") == ["e:Dorfkino", "e:Neuland"], "blank query: entries only: \(combine("   "))")
check(combine(">") == ["c:Neuer Tab", "c:Tab schließen", "c:Dateien"], "> alone: all commands in order: \(combine(">"))")
check(combine("> tab") == ["c:Neuer Tab", "c:Tab schließen"], "> tab: matching commands only: \(combine("> tab"))")
check(combine(">zzz").isEmpty, "> with no match: nothing")
check(combine("dorf") == ["e:Dorfkino"], "a word only an entry has: \(combine("dorf"))")
check(combine("schließ") == ["c:Tab schließen"], "a word only a command has: \(combine("schließ"))")
// "neu" starts a word in both "Neuland" and "Neuer Tab", the same score:
// the entry comes first.
check(combine("neu") == ["e:Neuland", "c:Neuer Tab"], "tie: entry before command: \(combine("neu"))")
// Same score among commands: their given order.
check(combine("tab") == ["c:Neuer Tab", "c:Tab schließen"], "tab: commands in order on a tie: \(combine("tab"))")
// A better score wins over the kind: "dat" starts "Dateien" (6 + 1) but is
// only inside "Update" (4 + 1).
let better = names(PaletteResults.combine(
    entries: [Item(name: "Update")],
    entryFields: { [$0.name] },
    commands: commands,
    commandFields: { [$0.name] },
    query: PaletteQuery.parse("dat")
))
check(better == ["c:Dateien", "e:Update"], "higher score first, command before entry: \(better)")

// MARK: CommandShortcut.display

check(Shortcuts.nextTab.display == "⇧⌘]", "next tab: \(Shortcuts.nextTab.display)")
check(Shortcuts.controlC.display == "⌃C", "control-c: \(Shortcuts.controlC.display)")
check(Shortcuts.arrowUp.display == "⌥⌘↑", "arrow up: \(Shortcuts.arrowUp.display)")
check(Shortcuts.enter.display == "⇧⌘↩", "enter: \(Shortcuts.enter.display)")
check(Shortcuts.switcher.display == "⌘K", "switcher: \(Shortcuts.switcher.display)")
check(Shortcuts.option(2).display == "⌥⌘2", "option 2: \(Shortcuts.option(2).display)")
check(CommandShortcut("x", [.command, .control, .shift, .option]).display == "⌃⌥⇧⌘X", "all modifiers in macOS order")

// MARK: PaletteCommand

let command = PaletteCommand(id: "space.newTab", title: "Neuer Tab", section: .space, keywords: ["tab"]) {}
check(command.fields == ["Neuer Tab", "tab", PaletteCommand.Section.space.name], "fields: title, keywords, section: \(command.fields)")
var ran = 0
let open = PaletteCommand(id: "x", title: "X", section: .app) { ran += 1 }
var allowed = false
let guarded = open.guarded { allowed }
guarded.run()
check(ran == 0, "guarded command does not run while not allowed")
allowed = true
guarded.run()
check(ran == 1, "guarded command runs once allowed")

// MARK: SwitcherMatch (as before)

check(SwitcherMatch.score(["herdr-remote-core"], ["hrc"]) == 1, "scattered letters score 1")
check(SwitcherMatch.score(["herdr-remote-core"], ["remote"]) == 7, "word start in the first field: 6 + 1")
check(SwitcherMatch.score(["x", "herdr-remote-core"], ["emote"]) == 4, "substring in another field: 4")
check(SwitcherMatch.score(["dorfkino"], ["zz"]) == nil, "no match: nil")
let filtered = SwitcherMatch.filter(["Remote", "herdr-remote-core", "Mail"], fields: { [$0] }, query: "remote")
check(filtered == ["Remote", "herdr-remote-core"], "filter keeps the best first: \(filtered)")
check(SwitcherMatch.filter(["b", "a"], fields: { [$0] }, query: " ") == ["b", "a"], "filter without words keeps all in order")

if failures > 0 { exit(1) }
print("command-palette: ok")
