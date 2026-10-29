// Checks that an answer button only answers the question it was shown for
// (#286), without the UI. Built by scripts/question-binding-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

let asked = QuestionBinding.info([("1", "Yes"), ("2", "Yes, and don't ask again"), ("3", "No")])

// MARK: Same question

check(asked == [["1", "Yes"], ["2", "Yes, and don't ask again"], ["3", "No"]], "info keeps all pairs: \(asked)")
check(QuestionBinding.stillAsked(shown: asked, now: asked), "same question is still asked")

// MARK: Another question

check(!QuestionBinding.stillAsked(shown: asked, now: [["1", "Yes"], ["2", "Allow all edits"], ["3", "No"]]),
      "changed label is another question")
check(!QuestionBinding.stillAsked(shown: asked, now: [["1", "Yes"], ["3", "Yes, and don't ask again"], ["2", "No"]]),
      "changed key is another question")
check(!QuestionBinding.stillAsked(shown: asked, now: [["3", "No"], ["2", "Yes, and don't ask again"], ["1", "Yes"]]),
      "changed order is another question")
check(!QuestionBinding.stillAsked(shown: asked, now: Array(asked.prefix(2))), "fewer options is another question")
check(!QuestionBinding.stillAsked(shown: asked, now: asked + [["4", "Skip"]]), "more options is another question")
check(!QuestionBinding.stillAsked(shown: asked, now: nil), "no question now is not the question shown")

// MARK: userInfo

let info: [AnyHashable: Any] = ["host": "h", "pane": "p", QuestionBinding.infoKey: asked]
check(QuestionBinding.shown(in: info) == asked, "info and shown give the same pairs")
check(QuestionBinding.shown(in: ["host": "h"]) == nil, "no question in userInfo")
check(QuestionBinding.shown(in: [QuestionBinding.infoKey: "1"]) == nil, "not a list")
check(QuestionBinding.shown(in: [QuestionBinding.infoKey: [["1"]]]) == nil, "pair without label")
check(QuestionBinding.shown(in: [QuestionBinding.infoKey: [["1", "Yes", "x"]]]) == nil, "pair with three values")
check(QuestionBinding.shown(in: [QuestionBinding.infoKey: [["1", "Yes"], [1, 2]]]) == nil, "pair without strings")

// A notification's userInfo goes through a property list.
let stored = try PropertyListSerialization.data(fromPropertyList: [QuestionBinding.infoKey: asked], format: .binary, options: 0)
let loaded = try PropertyListSerialization.propertyList(from: stored, format: nil) as? [AnyHashable: Any] ?? [:]
check(QuestionBinding.shown(in: loaded) == asked, "pairs survive a property list")

if failures > 0 { exit(1) }
print("question-binding: ok")
