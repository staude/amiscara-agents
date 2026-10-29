#if !os(tvOS)
import Foundation

// The rules for pull requests (#309) without network or UI, so
// scripts/pull-request-test.sh can check them.

/// Whether a pull request belongs to a space: its head is the space's
/// branch in the repository itself, not in a fork (owner without regard
/// to case).
func pullRequestMatches(headRefName: String, headOwner: String?, branch: String, repoOwner: String) -> Bool {
    headRefName == branch && headOwner?.lowercased() == repoOwner.lowercased()
}

/// How a pull request is merged, as GitHub's `merge_method`.
enum MergeMethod: String {
    case squash
    case merge
    case rebase
}

struct MergeMethods: Hashable {
    var squash: Bool
    var merge: Bool
    var rebase: Bool

    /// Squash where allowed, else a merge commit, else rebase.
    var preferred: MergeMethod? {
        if squash { return .squash }
        if merge { return .merge }
        if rebase { return .rebase }
        return nil
    }
}

/// The combined state of a commit's checks and statuses.
enum CheckState: Hashable {
    case success
    case failure
    case pending

    init(rollup state: String) {
        switch state {
        case "SUCCESS": self = .success
        case "PENDING", "EXPECTED": self = .pending
        default: self = .failure
        }
    }

    /// A check run: pending until completed, then by its conclusion.
    init(status: String?, conclusion: String?) {
        switch (status, conclusion) {
        case ("COMPLETED", "SUCCESS"), ("COMPLETED", "NEUTRAL"), ("COMPLETED", "SKIPPED"): self = .success
        case ("COMPLETED", _): self = .failure
        default: self = .pending
        }
    }
}
#endif
