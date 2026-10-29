import Foundation

/// Binds a notification's answer buttons to the question they were made
/// for (#286): the options go into `userInfo`, and a button only answers
/// while the pane still asks exactly that question. Otherwise the same key
/// could answer a newer question with another meaning, up to an approval.
enum QuestionBinding {
    /// The `userInfo` key holding the options as `[[key, label]]`.
    static let infoKey = "question"

    /// All options of a question as `[key, label]` pairs, not only the
    /// ones shown as buttons.
    static func info(_ options: [(key: String, label: String)]) -> [[String]] {
        options.map { [$0.key, $0.label] }
    }

    /// The options a notification was shown for; `nil` when it has none
    /// or they cannot be read.
    static func shown(in userInfo: [AnyHashable: Any]) -> [[String]]? {
        guard let pairs = userInfo[infoKey] as? [Any] else { return nil }
        var options: [[String]] = []
        for pair in pairs {
            guard let pair = pair as? [String], pair.count == 2 else { return nil }
            options.append(pair)
        }
        return options
    }

    /// True when the pane still asks the question shown: same options in
    /// the same order, with the same keys and labels.
    static func stillAsked(shown: [[String]], now: [[String]]?) -> Bool {
        guard let now else { return false }
        return shown == now
    }
}
