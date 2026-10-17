// End-to-end check of the Swift bindings without the UI: connect to a herdr
// server, wait for the board, follow one pane. Read-only.
//
// Usage: ffi-smoke [socket-path]    (default: ~/.config/herdr/herdr.sock)
import Foundation

final class Probe: SessionObserver, PaneObserver, @unchecked Sendable {
    let lock = NSLock()
    var update: SessionUpdate?
    var content: PaneContent?
    var paneError: String?

    func onUpdate(update: SessionUpdate) { lock.withLock { self.update = update } }
    func onContent(content: PaneContent) { lock.withLock { self.content = content } }
    func onError(message: String) { lock.withLock { paneError = message } }
}

func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return done()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

// Keys and the authorized_keys line.
let key = try generateSshKey(comment: "ffi-smoke")
guard key.publicOpenssh.hasPrefix("ssh-ed25519 "), key.fingerprint.hasPrefix("SHA256:") else {
    fail("generated key looks wrong")
}
let line = try authorizedKeysLine(publicOpenssh: key.publicOpenssh)
guard line.hasPrefix("restrict,port-forwarding,command=\"/usr/bin/false\" ssh-ed25519 ") else {
    fail("authorized_keys line: \(line)")
}
if (try? authorizedKeysLine(publicOpenssh: key.publicOpenssh + "\nssh-ed25519 AAAA x")) != nil {
    fail("multi-line public key was accepted")
}
print("ok   keys: \(key.fingerprint)")

// Live session.
let probe = Probe()
let socket = CommandLine.arguments.dropFirst().first
let session = try HostSession.start(endpoint: .local(socketPath: socket), observer: probe)
let live = wait(5) {
    probe.lock.withLock {
        if case .live = probe.update?.status { return true }
        return false
    }
}
guard live, let update = probe.lock.withLock({ probe.update }) else {
    fail("no live session: \(String(describing: probe.update?.status))")
}
let panes = update.workspaces.flatMap(\.tabs).flatMap(\.panes)
print("ok   live: herdr \(update.serverVersion ?? "?"), \(update.workspaces.count) workspaces, \(panes.count) panes, \(update.board.count) on the board")
guard update.protocolSupported else { fail("protocol not supported") }

guard let pane = update.board.first?.paneId ?? panes.first?.paneId else {
    print("skip pane: server has no panes")
    exit(0)
}
let follow = session.followPane(paneId: pane, observer: probe)
let gotContent = wait(5) { probe.lock.withLock { probe.content != nil } }
guard gotContent, let content = probe.lock.withLock({ probe.content }) else {
    fail("no content for \(pane): \(probe.paneError ?? "-")")
}
let spans = content.lines.reduce(0) { $0 + $1.spans.count }
print("ok   pane \(pane): \(content.lines.count) lines, \(spans) spans")
follow.stop()
session.stop()

// Optional: the SSH flow of the app. Set HERDR_SMOKE_SSH=user@host and
// HERDR_SMOKE_KEY=/path/to/private_key (a key allowed in authorized_keys).
let env = ProcessInfo.processInfo.environment
if let target = env["HERDR_SMOKE_SSH"], let keyPath = env["HERDR_SMOKE_KEY"] {
    let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("HERDR_SMOKE_SSH must be user@host") }
    let privateKey = try String(contentsOfFile: (keyPath as NSString).expandingTildeInPath, encoding: .utf8)
    func ssh(pinned: String?) -> Endpoint {
        .ssh(host: parts[1], port: 22, user: parts[0], privateKeyOpenssh: privateKey,
             pinnedHostKey: pinned, socketPath: defaultRemoteSocket(user: parts[0]))
    }

    let first = Probe()
    let unpinned = try HostSession.start(endpoint: ssh(pinned: nil), observer: first)
    var hostKey: String?
    _ = wait(10) {
        first.lock.withLock {
            if case .hostKeyUnknown(let key, let fingerprint) = first.update?.status {
                hostKey = key
                print("ok   ssh first contact asks: \(fingerprint)")
                return true
            }
            return false
        }
    }
    unpinned.stop()
    guard let hostKey else { fail("expected hostKeyUnknown, got \(String(describing: first.update?.status))") }

    let second = Probe()
    let pinned = try HostSession.start(endpoint: ssh(pinned: hostKey), observer: second)
    let sshLive = wait(10) {
        second.lock.withLock {
            if case .live = second.update?.status { return true }
            return false
        }
    }
    guard sshLive else { fail("ssh with pinned key not live: \(String(describing: second.update?.status))") }
    print("ok   ssh pinned: live, \(second.update?.board.count ?? 0) on the board")
    pinned.stop()

    let third = Probe()
    let wrong = try HostSession.start(endpoint: ssh(pinned: key.publicOpenssh), observer: third)
    let refused = wait(10) {
        third.lock.withLock {
            if case .hostKeyChanged = third.update?.status { return true }
            return false
        }
    }
    wrong.stop()
    guard refused else { fail("wrong pinned key not refused: \(String(describing: third.update?.status))") }
    print("ok   ssh wrong pin: refused as changed")
}
print("PASS")
