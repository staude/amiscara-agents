/// What to send so an agent's input line goes from `typed` to `target`:
/// backspaces for everything after the common start, then the new rest.
/// Used by the live mode of the input bar (slash commands typed straight
/// into Claude Code, so it shows its own suggestions in the pane).
struct LiveEdit: Equatable {
    let erase: Int
    let insert: String

    init(from typed: String, to target: String) {
        let common = zip(typed, target).prefix { $0 == $1 }.count
        erase = typed.count - common
        insert = String(target.dropFirst(common))
    }

    var isEmpty: Bool { erase == 0 && insert.isEmpty }
}
