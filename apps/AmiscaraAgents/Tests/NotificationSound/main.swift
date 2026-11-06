// Checks how the notification sound per state is stored and read (#336),
// without the UI. Built by scripts/notification-sound-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// MARK: Defaults

check(NotificationSound(stored: "", waiting: true) == .standard, "waiting defaults to the standard sound")
check(NotificationSound(stored: "", waiting: false) == .none, "done defaults to no sound")
check(NotificationSound.fallback(waiting: true) == .standard, "fallback waiting")
check(NotificationSound.fallback(waiting: false) == .none, "fallback done")

// MARK: Round trip

let all: [NotificationSound] = [.none, .standard, .app("chime"), .app("knock"), .system("Glass"), .file("Amiscara Agents - Ping.wav")]
for sound in all {
    for waiting in [true, false] {
        check(NotificationSound(stored: sound.stored, waiting: waiting) == sound, "\(sound.stored) survives storing (waiting \(waiting))")
    }
}
check(NotificationSound(stored: "none", waiting: true) == .none, "waiting can be switched to none")
check(NotificationSound(stored: "default", waiting: false) == .standard, "done can be switched to the standard sound")

// MARK: Unknown strings

for bad in ["bogus", "app:", "app:nope", "system:", "file:", ":x", "app:../x", "file:a/b", "sound:chime"] {
    check(NotificationSound(stored: bad, waiting: true) == .standard, "\(bad) falls back to the default of waiting")
    check(NotificationSound(stored: bad, waiting: false) == .none, "\(bad) falls back to the default of done")
}

// MARK: Names

check(NotificationSound.none.fileName == nil, "none has no file")
check(NotificationSound.standard.fileName == nil, "standard has no file")
check(NotificationSound.app("chime").fileName == "chime.caf", "app tone file")
check(NotificationSound.system("Glass").fileName == "Glass.aiff", "system sound file")
check(NotificationSound.file("Amiscara Agents - Ping.wav").fileName == "Amiscara Agents - Ping.wav", "own file keeps its name")

check(NotificationSound.none.pushSoundName == nil, "none pushes silently")
check(NotificationSound.standard.pushSoundName == "default", "standard pushes the default")
check(NotificationSound.app("rising").pushSoundName == "rising.caf", "app tone pushes its file")
check(NotificationSound.system("Glass").pushSoundName == nil, "system sound is no push sound")
check(NotificationSound.file("x.wav").pushSoundName == nil, "own file is no push sound")

check(NotificationSound.systemCopyName("Glass") == "Amiscara Agents System - Glass.aiff", "system copy name")
check(!NotificationSound.systemCopyName("Glass").hasPrefix(NotificationSound.filePrefix), "system copy is no own file")

// MARK: UserDefaults

let suite = UserDefaults(suiteName: "notification-sound-test")!
suite.removePersistentDomain(forName: "notification-sound-test")
check(NotificationSound.current(waiting: true, defaults: suite) == .standard, "nothing stored: waiting standard")
check(NotificationSound.current(waiting: false, defaults: suite) == .none, "nothing stored: done none")
suite.set(NotificationSound.app("falling").stored, forKey: NotificationSound.doneKey)
suite.set(NotificationSound.none.stored, forKey: NotificationSound.waitingKey)
check(NotificationSound.current(waiting: false, defaults: suite) == .app("falling"), "stored done choice")
check(NotificationSound.current(waiting: true, defaults: suite) == .none, "stored waiting choice")
suite.removePersistentDomain(forName: "notification-sound-test")

if failures == 0 {
    print("notification-sound-test: all checks passed")
} else {
    print("notification-sound-test: \(failures) failed")
    exit(1)
}
