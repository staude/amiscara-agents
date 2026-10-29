// Checks the rules for pull requests (#309) without network or UI: which
// pull request belongs to a space, the merge method, the check states.
// Built by scripts/pull-request-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// MARK: Pull request of a space

check(pullRequestMatches(headRefName: "feature/309-x", headOwner: "staude", branch: "feature/309-x", repoOwner: "staude"),
      "same branch in the repository")
check(pullRequestMatches(headRefName: "main", headOwner: "Immoticket24", branch: "main", repoOwner: "immoticket24"),
      "owner without regard to case")
check(!pullRequestMatches(headRefName: "main", headOwner: "someone", branch: "main", repoOwner: "staude"),
      "a fork's branch of the same name is not the space's")
check(!pullRequestMatches(headRefName: "main", headOwner: nil, branch: "main", repoOwner: "staude"),
      "a deleted head repository matches nothing")
check(!pullRequestMatches(headRefName: "feature/a", headOwner: "staude", branch: "feature/b", repoOwner: "staude"),
      "other branch")
check(!pullRequestMatches(headRefName: "Feature/A", headOwner: "staude", branch: "feature/a", repoOwner: "staude"),
      "branches keep their case")

// MARK: Merge method

check(MergeMethods(squash: true, merge: true, rebase: true).preferred == .squash, "squash first")
check(MergeMethods(squash: false, merge: true, rebase: true).preferred == .merge, "then a merge commit")
check(MergeMethods(squash: false, merge: false, rebase: true).preferred == .rebase, "then rebase")
check(MergeMethods(squash: false, merge: false, rebase: false).preferred == nil, "none allowed")

// MARK: Check states

check(CheckState(rollup: "SUCCESS") == .success, "rollup success")
check(CheckState(rollup: "PENDING") == .pending, "rollup pending")
check(CheckState(rollup: "EXPECTED") == .pending, "rollup expected")
check(CheckState(rollup: "FAILURE") == .failure, "rollup failure")
check(CheckState(rollup: "ERROR") == .failure, "rollup error")
check(CheckState(status: "COMPLETED", conclusion: "SUCCESS") == .success, "run passed")
check(CheckState(status: "COMPLETED", conclusion: "SKIPPED") == .success, "run skipped")
check(CheckState(status: "COMPLETED", conclusion: "NEUTRAL") == .success, "run neutral")
check(CheckState(status: "COMPLETED", conclusion: "FAILURE") == .failure, "run failed")
check(CheckState(status: "COMPLETED", conclusion: "CANCELLED") == .failure, "run cancelled")
check(CheckState(status: "COMPLETED", conclusion: "TIMED_OUT") == .failure, "run timed out")
check(CheckState(status: "IN_PROGRESS", conclusion: nil) == .pending, "run in progress")
check(CheckState(status: "QUEUED", conclusion: nil) == .pending, "run queued")

if failures > 0 {
    print("pull-requests: \(failures) failed")
    exit(1)
}
print("pull-requests: ok")
