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
let line = try authorizedKeysLine(publicOpenssh: key.publicOpenssh, allowSftp: false)
guard line.hasPrefix("restrict,port-forwarding,command=\"/usr/bin/false\" ssh-ed25519 ") else {
    fail("authorized_keys line: \(line)")
}
let sftpLine = try authorizedKeysLine(publicOpenssh: key.publicOpenssh, allowSftp: true)
guard sftpLine.hasPrefix("restrict,port-forwarding,command=\"/usr/libexec/sftp-server\" ssh-ed25519 ") else {
    fail("authorized_keys line with SFTP: \(sftpLine)")
}
if (try? authorizedKeysLine(publicOpenssh: key.publicOpenssh + "\nssh-ed25519 AAAA x", allowSftp: false)) != nil {
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
// Upload on the local host writes straight into ~/.herdr-remote/uploads.
let payload = Data("herdr-remote smoke \(UUID().uuidString)".utf8)
let localPath = try session.uploadFile(data: payload, fileExtension: "txt")
guard FileManager.default.contents(atPath: localPath) == payload else { fail("local upload content: \(localPath)") }
try? FileManager.default.removeItem(atPath: localPath)
if (try? session.uploadFile(data: payload, fileExtension: "../x")) != nil { fail("bad extension accepted") }
print("ok   upload local: \(localPath)")

let follow = session.followPane(paneId: pane, observer: probe)
let gotContent = wait(5) { probe.lock.withLock { probe.content != nil } }
guard gotContent, let content = probe.lock.withLock({ probe.content }) else {
    fail("no content for \(pane): \(probe.paneError ?? "-")")
}
let spans = content.lines.reduce(0) { $0 + $1.spans.count }
print("ok   pane \(pane): \(content.lines.count) lines, \(spans) spans")
follow.stop()
session.stop()

// Optional: input. Writes into a pane, so it only runs against an explicit
// test session (HERDR_SMOKE_WRITE_SOCKET), never the default socket.
let env = ProcessInfo.processInfo.environment
if let writeSocket = env["HERDR_SMOKE_WRITE_SOCKET"] {
    let defaultSocket = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/herdr/herdr.sock").path
    guard writeSocket != defaultSocket, writeSocket.contains("/sessions/") else {
        fail("HERDR_SMOKE_WRITE_SOCKET must point to a named test session, not \(writeSocket)")
    }
    let probe = Probe()
    let session = try HostSession.start(endpoint: .local(socketPath: writeSocket), observer: probe)
    let live = wait(5) {
        probe.lock.withLock {
            if case .live = probe.update?.status { return true }
            return false
        }
    }
    guard live, let shell = probe.lock.withLock({
        probe.update?.workspaces.flatMap(\.tabs).flatMap(\.panes).first { $0.agent == nil }
    }) else {
        fail("test session has no shell pane")
    }
    let follow = session.followPane(paneId: shell.paneId, observer: probe)
    let marker = "herdr-remote-\(UInt32.random(in: 100_000...999_999))"
    try session.sendText(paneId: shell.paneId, text: "echo \(marker)-ok")
    try session.sendKeys(paneId: shell.paneId, keys: ["enter"])
    let echoed = wait(5) {
        probe.lock.withLock {
            probe.content?.lines.contains { line in
                line.spans.map(\.text).joined().trimmingCharacters(in: .whitespaces) == "\(marker)-ok"
            } ?? false
        }
    }
    guard echoed else { fail("echo output did not appear in \(shell.paneId)") }
    print("ok   input: text + enter reached \(shell.paneId)")

    do {
        try session.sendPrompt(paneId: shell.paneId, text: "hello")
        fail("prompt to a shell was accepted")
    } catch let error as FfiError {
        print("ok   input: prompt to a shell refused (\(error))")
    }
    do {
        try session.sendKeys(paneId: shell.paneId, keys: ["no-such-key"])
        fail("invalid key was accepted")
    } catch let error as FfiError {
        print("ok   input: invalid key refused (\(error))")
    }
    follow.stop()
    session.stop()
}

// Optional: the SSH flow of the app. Set HERDR_SMOKE_SSH=user@host and
// HERDR_SMOKE_KEY=/path/to/private_key (a key allowed in authorized_keys).
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

    // Upload over SFTP. Works only when the key line runs sftp-server.
    do {
        let remotePath = try pinned.uploadFile(data: payload, fileExtension: "txt")
        // The smoke test runs on the host itself when HERDR_SMOKE_SSH points at it.
        if FileManager.default.fileExists(atPath: remotePath) {
            guard FileManager.default.contents(atPath: remotePath) == payload else { fail("sftp upload content") }
            try? FileManager.default.removeItem(atPath: remotePath)
        }
        print("ok   ssh upload: \(remotePath)")
    } catch {
        print("info ssh upload refused: \(error)")
    }
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
