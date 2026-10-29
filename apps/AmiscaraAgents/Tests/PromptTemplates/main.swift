// Checks the prompt templates (#298) without the UI: placeholders, issue
// number from a branch, matching by repository, saving. Built by
// scripts/prompt-templates-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@MainActor func run() {
    check(PromptPlaceholders.names(in: "/issue-plan {nr}") == ["nr"], "finds a placeholder")
    check(PromptPlaceholders.names(in: "{nr} {branch} {nr}") == ["nr", "branch"], "each name once, in order")
    check(PromptPlaceholders.names(in: "{} { nr } {1x} plain").isEmpty, "malformed braces are no placeholders")

    let values = ["nr": "298"]
    check(PromptPlaceholders.fill("/issue-plan {nr} on {branch}", values: values) == "/issue-plan 298 on {branch}",
          "fills known values, keeps missing ones")
    check(PromptPlaceholders.fill("{nr}-{nr}", values: values) == "298-298", "fills repeated placeholders")
    check(PromptPlaceholders.fill("{a}", values: ["a": "{b}", "b": "x"]) == "{b}", "values are not expanded again")

    check(PromptPlaceholders.issueNumber(branch: "feature/123-slug") == "123", "number from feature branch")
    check(PromptPlaceholders.issueNumber(branch: "bug/7") == "7", "number at the end")
    check(PromptPlaceholders.issueNumber(branch: "main") == nil, "no number on main")
    check(PromptPlaceholders.issueNumber(branch: "feature/x-1") == nil, "number not at the start")
    check(PromptPlaceholders.issueNumber(branch: "feature/12x") == nil, "digits must end the number")

    check(PromptPlaceholders.prefills(branch: "feature/298-x", space: "agents")
          == ["nr": "298", "branch": "feature/298-x", "space": "agents"], "prefills all")
    check(PromptPlaceholders.prefills(branch: "main", space: nil) == ["branch": "main"], "prefills only what is known")
    check(PromptPlaceholders.prefills(branch: nil, space: "").isEmpty, "nothing known, nothing prefilled")

    let file = FileManager.default.temporaryDirectory.appending(path: "prompt-templates-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }

    let store = PromptTemplateStore(fileURL: file)
    check(store.templates.isEmpty, "first run has no templates")

    var all = store.add()
    all.text = "/compact"
    store.templates[0] = all
    var mine = store.add(repo: "amiscara-agents")
    mine.text = "/issue-plan {nr}"
    store.templates[1] = mine
    var other = store.add(repo: "enon")
    other.text = "Review PR {nr}"
    store.templates[2] = other
    _ = store.add()

    check(store.matching(repo: "amiscara-agents").map(\.id) == [all.id, mine.id], "same repo and all-repo templates")
    check(store.matching(repo: "enon").map(\.id) == [all.id, other.id], "a foreign repo sees only its own")
    check(store.matching(repo: nil).map(\.id) == [all.id], "no repo sees only the all-repo ones")
    check(mine.title == "/issue-plan {nr}", "title falls back to the text")

    store.removeBlank()
    check(store.templates.count == 3, "blank entries are dropped")

    let reloaded = PromptTemplateStore(fileURL: file)
    check(reloaded.templates == store.templates, "survives a restart")

    let broken = FileManager.default.temporaryDirectory.appending(path: "prompt-templates-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: broken) }
    try? Data("not json".utf8).write(to: broken)
    check(PromptTemplateStore(fileURL: broken).templates.isEmpty, "unreadable file gives an empty list")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("prompt-templates: ok")
