import Foundation

/// The notes of one version from apps/whats-new.json (#341).
struct WhatsNewEntry: Decodable, Equatable, Identifiable, Sendable {
    let version: String
    let de: [String]
    let en: [String]

    var id: String { version }

    func notes(german: Bool) -> [String] { german ? de : en }
}

/// "Neuigkeiten" after an update (#341): which versions the window shows
/// and when. The notes come from apps/whats-new.json, which the Mac app
/// bundles; a release stops without notes for its version
/// (scripts/whats-new.py).
enum WhatsNew {
    /// The version whose notes the user has seen, in `UserDefaults.standard`.
    static let seenKey = "whatsNewSeenVersion"

    /// The bundled notes of the Mac app.
    static func bundled() -> [WhatsNewEntry] {
        entries(from: Bundle.main.url(forResource: "whats-new", withExtension: "json"), app: "mac")
    }

    /// The installed version, e.g. "0.2.0".
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// German when the app runs in German, else English.
    static var prefersGerman: Bool {
        (Bundle.main.preferredLocalizations.first ?? "").lowercased().hasPrefix("de")
    }

    /// The entries of `app` ("mac" or "desktop"); empty when the file is
    /// missing or broken, without the entries it cannot read.
    static func entries(from url: URL?, app: String) -> [WhatsNewEntry] {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = file[app] as? [Any]
        else { return [] }
        return list.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let json = try? JSONSerialization.data(withJSONObject: item)
            else { return nil }
            return try? JSONDecoder().decode(WhatsNewEntry.self, from: json)
        }
    }

    /// "1.2.3" as three numbers; nil for anything else.
    static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    /// Whether `a` comes before `b`; 0.9.0 before 0.10.0.
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    /// The versions after `seen` up to `current`, newest first.
    static func pending(_ entries: [WhatsNewEntry], seen: String, current: String) -> [WhatsNewEntry] {
        guard let seen = parse(seen), let current = parse(current) else { return [] }
        return sorted(entries) { !isOlder($0, than: seen) && $0 != seen && !isOlder(current, than: $0) }
    }

    /// All versions up to `current`, newest first.
    static func history(_ entries: [WhatsNewEntry], current: String) -> [WhatsNewEntry] {
        guard let current = parse(current) else { return [] }
        return sorted(entries) { !isOlder(current, than: $0) }
    }

    /// On start: what to show once, and the installed version noted as
    /// seen. The first start shows nothing, a downgrade neither.
    static func onLaunch(
        _ entries: [WhatsNewEntry],
        current: String,
        defaults: UserDefaults = .standard
    ) -> [WhatsNewEntry] {
        let seen = defaults.string(forKey: seenKey)
        defaults.set(current, forKey: seenKey)
        guard let seen, seen != current else { return [] }
        return pending(entries, seen: seen, current: current)
    }

    private static func sorted(_ entries: [WhatsNewEntry], where keep: ([Int]) -> Bool) -> [WhatsNewEntry] {
        entries
            .compactMap { entry in parse(entry.version).map { (entry, $0) } }
            .filter { keep($0.1) }
            .sorted { isOlder($1.1, than: $0.1) }
            .map(\.0)
    }
}
