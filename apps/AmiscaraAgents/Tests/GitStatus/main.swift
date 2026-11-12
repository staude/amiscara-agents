// Checks the rules for the Git status of worktree spaces (#343) without
// the core or UI: when to read it again, the pacing of runs, the text of a
// row, the button "Änderungen" (#359) and the search of "Worktree öffnen".
// Built by scripts/git-status-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// MARK: Reasons to read again

let main = GitSpace(workspaceID: "w1", repoKey: "/r/.git", branch: "main")
let feature = GitSpace(workspaceID: "w2", repoKey: "/r/.git", branch: "feature/x")
let renamed = GitSpace(workspaceID: "w2", repoKey: "/r/.git", branch: "feature/y")

func occasion(_ before: [GitSpace], _ after: [GitSpace], wasLive: Bool = true, isLive: Bool = true,
              working: Set<String> = [], now: Set<String> = []) -> Bool {
    gitStatusOccasion(before: before, after: after, wasLive: wasLive, isLive: isLive,
                      workingBefore: working, workingAfter: now)
}

check(!occasion([main, feature], [main, feature]), "nothing changed")
check(occasion([main], [main, feature]), "a new space")
check(occasion([main, feature], [main, renamed]), "another branch")
check(occasion([main, feature], [main, feature], wasLive: false), "the host came back")
check(!occasion([main], [main, feature], isLive: false), "not while offline")
check(occasion([main, feature], [main, feature], working: ["w2"], now: []), "an agent stopped working")
check(!occasion([main, feature], [main, feature], working: [], now: ["w2"]), "an agent started")
check(!occasion([main, feature], [main, feature], working: ["w9"], now: []), "an agent outside Git stopped")

// MARK: Pacing

let t0 = Date(timeIntervalSince1970: 1_000_000)
var pacing = GitStatusPacing()
check(pacing.occasion(at: t0) == .now, "the first reason runs at once")
pacing.started(at: t0)
check(pacing.occasion(at: t0 + 5) == .at(t0 + 20), "while running: a follow-up 20 s after the start")
check(pacing.occasion(at: t0 + 6) == .waiting, "further reasons join the follow-up")
check(!pacing.finished(), "the follow-up waits for its time, not for the run")
check(pacing.followUpDue(), "the follow-up starts when nothing runs")
pacing.started(at: t0 + 20)
check(pacing.occasion(at: t0 + 25) == .at(t0 + 40), "a reason soon after the follow-up waits again")
check(!pacing.followUpDue(), "a follow-up during a long run waits for it")
check(pacing.finished(), "then it starts when the run is done")
pacing.started(at: t0 + 50)
check(!pacing.finished(), "a run without follow-up ends quietly")
check(pacing.occasion(at: t0 + 80) == .now, "a reason later than 20 s runs at once")
pacing.started(at: t0 + 80)
_ = pacing.finished()
check(pacing.occasion(at: t0 + 85) == .at(t0 + 100), "soon after a finished run: a follow-up")
pacing.reset()
check(pacing.occasion(at: t0 + 101) == .now, "after a reset nothing waits")

// MARK: Row text

check(gitStatusText(hasUpstream: true, ahead: 0, behind: 0, changes: 0) == "", "even and clean: nothing")
check(gitStatusText(hasUpstream: true, ahead: 3, behind: 2, changes: 4) == "↑3 ↓2 ● 4 geändert", "all of it")
check(gitStatusText(hasUpstream: true, ahead: 1, behind: 0, changes: 0) == "↑1", "only ahead")
check(gitStatusText(hasUpstream: true, ahead: 0, behind: 5, changes: 0) == "↓5", "only behind")
check(gitStatusText(hasUpstream: false, ahead: 0, behind: 0, changes: 0) == "kein Upstream", "never pushed")
check(gitStatusText(hasUpstream: false, ahead: 7, behind: 0, changes: 1) == "kein Upstream ● 1 geändert",
      "no counts without upstream")

// MARK: Button "Änderungen"

func button(automatic: Bool, git: Bool = true, status: UInt32? = nil, loaded: Int? = nil) -> ChangesButton {
    changesButton(automatic: automatic, gitSpace: git, statusChanges: status, loadedCount: loaded)
}

check(button(automatic: true, status: 0) == .hidden, "automatic: hidden without changes")
check(button(automatic: true, status: 4) == .shown(count: 4), "automatic: with the number of changes")
check(button(automatic: true, git: false, status: 2) == .shown(count: 2), "automatic: a herdr desktop space with changes")
check(button(automatic: true, loaded: 3) == .shown(count: 3), "automatic: the loaded number before a status")
check(button(automatic: true) == .hidden, "automatic: hidden before anything is known")
check(button(automatic: true, status: 5, loaded: 3) == .shown(count: 5), "the status counts before the load")
check(button(automatic: false) == .shown(count: nil), "without herdr-core: every Git space, no number yet")
check(button(automatic: false, status: 0) == .shown(count: nil), "without herdr-core: no number without changes")
check(button(automatic: false, status: 4) == .shown(count: 4), "without herdr-core: the number of the status")
check(button(automatic: false, loaded: 2) == .shown(count: 2), "without herdr-core: the loaded number")
check(button(automatic: false, git: false, status: 3) == .hidden, "without herdr-core: not outside a Git space")

check(isHostCoreSpace("hc:t1"), "a herdr-core terminal on the host")
check(isHostCoreSpace("hc:dir:/Users/f/r"), "a herdr-core directory space on the host")
check(isHostCoreSpace("hc:tab:t1"), "a herdr-core tab space on the host")
check(!isHostCoreSpace("hc:box/t1"), "a terminal on another machine")
check(!isHostCoreSpace("hc:dir:box/Users/f/r"), "a directory on another machine")
check(!isHostCoreSpace("w1"), "a space of the herdr server")

// MARK: Search

check(worktreeMatches("", branch: nil, label: "x", path: "/x"), "empty search shows all")
check(worktreeMatches("Mac ARCHIVE", branch: "fix/mac-archive-team", label: "fix-mac-archive-team", path: "/r/.worktrees/fix-mac-archive-team"),
      "words without regard to case")
check(worktreeMatches("termlight", branch: nil, label: "amiscara-agents-termlight", path: "/d/amiscara-agents-termlight"),
      "a detached worktree by its name")
check(worktreeMatches("worktrees", branch: "a", label: "b", path: "/r/.worktrees/b"), "by path")
check(!worktreeMatches("mac other", branch: "fix/mac", label: "fix-mac", path: "/r/fix-mac"), "every word must match")

if failures > 0 {
    print("git-status: \(failures) failed")
    exit(1)
}
print("git-status: ok")
