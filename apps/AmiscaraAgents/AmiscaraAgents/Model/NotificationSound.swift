import Foundation

/// The sound of a notification for an agent that waits or is done (#336),
/// chosen per state in the settings. Kept as a string in `UserDefaults`:
/// `none`, `default`, `app:<name>`, `system:<name>` or `file:<file name>`.
/// Foundation only, so the check in Tests/NotificationSound builds it alone.
enum NotificationSound: Equatable, Sendable {
    /// No sound.
    case none
    /// The system's default notification sound.
    case standard
    /// A tone built into the app (`Sounds/<name>.caf`), on every device.
    case app(String)
    /// A system sound of the Mac (`/System/Library/Sounds/<name>.aiff`).
    case system(String)
    /// A file the user added on the Mac, in `~/Library/Sounds`.
    case file(String)

    static let waitingKey = "notificationSoundWaiting"
    static let doneKey = "notificationSoundDone"

    /// The tones the app brings, in the order the settings list them.
    static let appTones = ["chime", "rising", "falling", "knock"]

    /// Files the user added start with this, so the list shows only those
    /// and not everything else in `~/Library/Sounds`.
    static let filePrefix = "Amiscara Agents - "

    /// Where the system finds sounds a user adds: `~/Library/Sounds`.
    static var userSoundsFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The name of a system sound's copy in `~/Library/Sounds`; it does not
    /// start with `filePrefix`, so the list of own files leaves it out.
    static func systemCopyName(_ name: String) -> String { "Amiscara Agents System - \(name).aiff" }

    /// Without a choice, "waits" sounds as before and "done" stays silent.
    static func fallback(waiting: Bool) -> NotificationSound { waiting ? .standard : .none }

    static func key(waiting: Bool) -> String { waiting ? waitingKey : doneKey }

    /// Reads a stored string; empty or unknown gives the state's default.
    init(stored: String, waiting: Bool) {
        switch stored {
        case "none":
            self = .none
        case "default":
            self = .standard
        default:
            let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty, !parts[1].contains("/") else {
                self = Self.fallback(waiting: waiting)
                return
            }
            switch parts[0] {
            case "app" where Self.appTones.contains(parts[1]): self = .app(parts[1])
            case "system": self = .system(parts[1])
            case "file": self = .file(parts[1])
            default: self = Self.fallback(waiting: waiting)
            }
        }
    }

    /// The string `init(stored:waiting:)` reads back.
    var stored: String {
        switch self {
        case .none: "none"
        case .standard: "default"
        case .app(let name): "app:\(name)"
        case .system(let name): "system:\(name)"
        case .file(let name): "file:\(name)"
        }
    }

    /// The chosen sound for a state on this device.
    static func current(waiting: Bool, defaults: UserDefaults = .standard) -> NotificationSound {
        NotificationSound(stored: defaults.string(forKey: key(waiting: waiting)) ?? "", waiting: waiting)
    }

    /// The sound file's name for `UNNotificationSound(named:)`, nil for
    /// `none` and `standard`.
    var fileName: String? {
        switch self {
        case .none, .standard: nil
        case .app(let name): "\(name).caf"
        case .system(let name): "\(name).aiff"
        case .file(let name): name
        }
    }

    /// The sound name of a CloudKit subscription's push (#119), which the
    /// phone names itself. Only the default and the app's own tones exist
    /// there; a system sound or file of the Mac cannot reach it.
    var pushSoundName: String? {
        switch self {
        case .standard: "default"
        case .app: fileName
        case .none, .system, .file: nil
        }
    }
}
