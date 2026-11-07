#if !os(tvOS)
import Foundation

// The rules for the Git status of worktree spaces (#343) without the core
// or UI, so scripts/git-status-test.sh can check them: when to read it
// again, how often, and the text of a row.

/// A space showing a Git checkout, as far as its status depends on it.
struct GitSpace: Equatable {
    let workspaceID: String
    let repoKey: String
    let branch: String
}

/// Whether a session update is a reason to read the status again: other
/// spaces or branches, the host back, or an agent in a Git space that
/// stopped working. `working` holds the workspace IDs whose agent works.
func gitStatusOccasion(
    before: [GitSpace], after: [GitSpace],
    wasLive: Bool, isLive: Bool,
    workingBefore: Set<String>, workingAfter: Set<String>
) -> Bool {
    guard isLive else { return false }
    if before != after || !wasLive { return true }
    let gitSpaces = Set(after.map(\.workspaceID))
    return !workingBefore.subtracting(workingAfter).intersection(gitSpaces).isEmpty
}

/// What to do with a reason to read the status.
enum GitStatusStart: Equatable {
    /// Start a run now.
    case now
    /// A follow-up at that time; nothing else until then.
    case at(Date)
    /// A follow-up is waiting already.
    case waiting
}

/// One run at a time, and reasons within `gap` of the last start gathered
/// into one follow-up `gap` after that start.
struct GitStatusPacing {
    static let gap: TimeInterval = 20

    private(set) var lastStart: Date?
    private(set) var running = false
    private(set) var followUp = false
    /// The follow-up came while a run was going: start it after that one.
    private var afterRun = false

    mutating func occasion(at now: Date) -> GitStatusStart {
        if followUp { return .waiting }
        let due = lastStart.map { $0.addingTimeInterval(Self.gap) } ?? now
        if !running, due <= now { return .now }
        followUp = true
        return .at(max(due, now))
    }

    mutating func started(at now: Date) {
        running = true
        lastStart = now
        followUp = false
        afterRun = false
    }

    /// The follow-up's time has come: `true` to start now, otherwise it
    /// starts when the running one is done.
    mutating func followUpDue() -> Bool {
        if running {
            afterRun = true
            return false
        }
        return true
    }

    /// A run is done: `true` when the follow-up waits for it.
    mutating func finished() -> Bool {
        running = false
        let start = afterRun
        afterRun = false
        return start
    }

    /// Nothing waits any more (no rights, no session).
    mutating func reset() {
        followUp = false
        afterRun = false
    }
}

/// The status line of a space: "↑3 ↓2 ● 4 geändert", "kein Upstream",
/// empty when the branch is even with its upstream and nothing changed.
func gitStatusText(hasUpstream: Bool, ahead: UInt32, behind: UInt32, changes: UInt32) -> String {
    var parts: [String] = []
    if hasUpstream {
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
    } else {
        parts.append(String(localized: "kein Upstream"))
    }
    if changes > 0 { parts.append(String(localized: "● \(Int(changes)) geändert")) }
    return parts.joined(separator: " ")
}

/// Whether `workspaceID` is a space of herdr-core on the host itself, not
/// of a machine connected to it (`hc:box/t1`), like `hc::machine_of` in
/// the core: only those get the host's Git status (#359).
func isHostCoreSpace(_ workspaceID: String) -> Bool {
    guard workspaceID.hasPrefix("hc:") else { return false }
    var rest = workspaceID.dropFirst(3)
    for kind in ["dir:", "tab:"] where rest.hasPrefix(kind) {
        rest = rest.dropFirst(kind.count)
        break
    }
    // A directory is absolute, so a machine comes before its first `/`.
    guard let slash = rest.firstIndex(of: "/") else { return true }
    return slash == rest.startIndex
}

/// The button "Änderungen" next to a space's tabs (#342, #359).
enum ChangesButton: Equatable {
    case hidden
    /// With the number of changed files when one is known and not 0.
    case shown(count: Int?)
}

/// Whether and with what number the button shows. `automatic`: the host's
/// Git status runs on its own without a tab (herdr-core, input and file
/// access), so the button shows only for a space with changes. Otherwise
/// it shows in every Git space, with the number once known. The number is
/// that of the Git status, else of the last loaded changes.
func changesButton(automatic: Bool, gitSpace: Bool, statusChanges: UInt32?, loadedCount: Int?) -> ChangesButton {
    let count = statusChanges.map { Int($0) } ?? loadedCount ?? 0
    if automatic {
        return count > 0 ? .shown(count: count) : .hidden
    }
    guard gitSpace else { return .hidden }
    return .shown(count: count > 0 ? count : nil)
}

/// Whether a worktree matches the search of "Worktree öffnen": branch,
/// name or path contain every word, without regard to case.
func worktreeMatches(_ query: String, branch: String?, label: String, path: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let text = [branch ?? "", label, path].joined(separator: "\n").lowercased()
    return words.allSatisfy { text.contains($0) }
}
#endif
