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
    /// Every attention item seen, in order.
    var attention: [BoardItem] = []

    func onUpdate(update: SessionUpdate) {
        lock.withLock {
            self.update = update
            attention += update.attention
        }
    }
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
let branchesSeen = wait(5) {
    probe.lock.withLock { probe.update?.workspaces.contains { $0.branch != nil } ?? false }
}
let spaces = probe.lock.withLock { probe.update?.workspaces ?? [] }
print("ok   spaces: " + spaces.map { "\($0.worktreeName.map { "└" + $0 } ?? $0.label)=\($0.branch ?? "-")" }.joined(separator: ", "))
if !branchesSeen { print("info no branch found for any space") }

guard let pane = update.board.first?.paneId ?? panes.first?.paneId else {
    print("skip pane: server has no panes")
    exit(0)
}
/// Uploads may be private screenshots: file 0600, directory 0700.
func checkPrivate(_ path: String) {
    let mode = { (p: String) in
        ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    let dir = (path as NSString).deletingLastPathComponent
    guard mode(path) == 0o600, mode(dir) == 0o700 else {
        fail(String(format: "upload permissions: file %o, dir %o", mode(path), mode(dir)))
    }
}

// Upload on the local host writes straight into ~/.herdr-remote/uploads.
let payload = Data("herdr-remote smoke \(UUID().uuidString)".utf8)
let localPath = try session.uploadFile(data: payload, fileExtension: "txt")
guard FileManager.default.contents(atPath: localPath) == payload else { fail("local upload content: \(localPath)") }
checkPrivate(localPath)
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

    // New space and tab; both must show up in the session state.
    let space = try session.createWorkspace(label: "smoke-space", cwd: "/tmp")
    let tab = try session.createTab(workspaceId: space.workspaceId, cwd: nil)
    let appeared = wait(5) {
        probe.lock.withLock {
            guard let ws = probe.update?.workspaces.first(where: { $0.workspaceId == space.workspaceId }) else { return false }
            return ws.label == "smoke-space" && ws.tabs.contains { $0.tabId == tab.tabId && $0.panes.contains { $0.paneId == tab.paneId } }
        }
    }
    guard appeared else { fail("created space \(space.workspaceId) / tab \(tab.tabId) not in the session") }

    // Attention: simulate an agent with pane.report_agent (herdr's own
    // integration call) and expect one notice for "blocked" and one for "done".
    func report(_ state: String) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = writeSocket.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, size) } }) == 0 else {
            fail("cannot reach the test socket")
        }
        let line = "{\"id\":\"smoke\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"\(tab.paneId)\",\"source\":\"ffi-smoke\",\"agent\":\"claude\",\"state\":\"\(state)\"}}\n"
        _ = line.withCString { send(socket, $0, strlen($0), 0) }
        var reply = [UInt8](repeating: 0, count: 4096)
        _ = recv(socket, &reply, reply.count, 0)
    }
    let noticed = { (status: AgentState) in
        wait(5) { probe.lock.withLock { probe.attention.contains { $0.paneId == tab.paneId && $0.agentState == status } } }
    }
    try report("working")
    try report("blocked")
    guard noticed(.blocked) else { fail("no attention for blocked") }
    try report("working")
    try report("idle")
    guard noticed(.done) else { fail("no attention for done") }
    let notices = probe.lock.withLock { probe.attention.filter { $0.paneId == tab.paneId } }
    guard notices.count == 2 else { fail("expected 2 notices, got \(notices.map(\.agentState))") }
    print("ok   attention: blocked and done, once each")
    print("ok   create: space \(space.workspaceId) with tab \(tab.tabId)")

    // Renames: space and tab arrive as events, the agent name with the
    // snapshot the session takes after the rename.
    let agentName = "smoke-\(UInt32.random(in: 1000...9999))"
    try session.renameWorkspace(workspaceId: space.workspaceId, label: "smoke-renamed")
    try session.renameTab(tabId: tab.tabId, label: "smoke-tab")
    try session.renameAgent(paneId: tab.paneId, name: agentName)
    let renamed = wait(5) {
        probe.lock.withLock {
            guard let update = probe.update,
                  let ws = update.workspaces.first(where: { $0.workspaceId == space.workspaceId }) else { return false }
            return ws.label == "smoke-renamed"
                && ws.tabs.contains { $0.tabId == tab.tabId && $0.label == "smoke-tab" }
                && update.board.contains { $0.paneId == tab.paneId && $0.name == agentName }
        }
    }
    guard renamed else { fail("renames did not arrive: \(String(describing: probe.update?.board.map(\.name)))") }
    do {
        try session.renameAgent(paneId: tab.paneId, name: "Not Valid")
        fail("invalid agent name was accepted")
    } catch FfiError.Rejected(let message) where message.contains("invalid_agent_name") {}
    do {
        try session.renameWorkspace(workspaceId: space.workspaceId, label: "  ")
        fail("empty space name was accepted")
    } catch FfiError.Rejected {}
    try session.renameAgent(paneId: tab.paneId, name: nil)
    let cleared = wait(5) {
        probe.lock.withLock { probe.update?.board.contains { $0.paneId == tab.paneId && $0.name == nil } ?? false }
    }
    guard cleared else { fail("agent name was not removed") }
    print("ok   rename: space, tab and agent \(agentName), then the name removed")
    do {
        _ = try session.createTab(workspaceId: "w999", cwd: nil)
        fail("tab in unknown space was accepted")
    } catch let error as FfiError {
        print("ok   create: unknown space refused (\(error))")
    }
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
            checkPrivate(remotePath)
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
