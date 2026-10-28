import Foundation
import Observation

/// One host with its live session. Rust calls back on a background thread;
/// the bridge hops to the main actor before anything touches the UI state.
@MainActor
@Observable
final class HostConnection: Identifiable {
    private(set) var config: HostConfig
    private(set) var update: SessionUpdate?
    private(set) var startError: String?
    /// When the host was last seen connected, for the overview (#274).
    private var liveClock = LiveClock()
    var liveAt: Date? { liveClock.liveAt }
    /// The agents of the last update while live, for the host dashboard
    /// (#278): a new session starts with an empty board, so they stay
    /// after "Neu verbinden" and editing, unless the server changed.
    /// Only in memory.
    private(set) var lastBoard: [BoardItem] = []
    @ObservationIgnored private var session: HostSession?
    /// Counts session starts. Pane followers end with their session, so a
    /// pane view follows its pane again when this changes.
    private(set) var generation = 0
    /// Called on the main actor after every update, e.g. for notifications.
    @ObservationIgnored var onUpdate: ((HostConnection, SessionUpdate) -> Void)?
    /// Token usage of the host's Claude agents (#302).
    @ObservationIgnored let usage = UsageStore()
    #if DEBUG
    /// The screenshot demo took the host offline (#290); late updates of
    /// the stopped session must not bring it back.
    @ObservationIgnored private var demoOffline = false
    #endif
    nonisolated let id: UUID

    init(config: HostConfig) {
        self.config = config
        id = config.id
        usage.attach(self)
    }

    var status: HostStatus? { update?.status }

    var isLive: Bool {
        if case .live = update?.status { return true }
        return false
    }

    func start() {
        stop()
        startError = nil
        do {
            let bridge = SessionBridge { [weak self] update in
                Task { @MainActor in
                    guard let self else { return }
                    #if DEBUG
                    if self.demoOffline { return }
                    #endif
                    let wasLive = self.isLive
                    self.update = update
                    self.liveClock.update(wasLive: wasLive, isLive: self.isLive)
                    if self.isLive { self.lastBoard = update.board }
                    self.onUpdate?(self, update)
                }
            }
            session = try HostSession.start(
                endpoint: try endpoint(),
                observer: bridge,
                groupSpacesByName: config.groupSpacesByName,
                spaceSort: config.spaceSorting
            )
            generation += 1
        } catch {
            startError = error.localizedDescription
        }
    }

    /// Connects again at once and keeps the known state, so agents that
    /// finished meanwhile still notify (#264). A session that has stopped
    /// (refused login, host key) starts over instead, also when its last
    /// update has not arrived yet.
    func reconnect() {
        liveClock.reconnecting(live: isLive)
        guard let session, session.reconnect() else { return start() }
    }

    func stop() {
        session?.stop()
        session = nil
        cachedAgentKinds = nil
    }

    #if DEBUG
    /// The screenshot demo's offline pane (#290): stops the session and
    /// shows the host as unreachable, while the demo server keeps running
    /// for the other platforms.
    func demoGoOffline() {
        demoOffline = true
        stop()
        update?.status = .retrying(attempt: 1, error: "Host nicht erreichbar")
    }
    #endif

    /// Replaces the configuration (after editing or trusting a host key)
    /// and reconnects. A change of the grouping alone goes to the running
    /// session instead, which sends a rebuilt update at once.
    func apply(_ config: HostConfig) {
        var regrouped = self.config
        regrouped.groupSpaces = config.groupSpaces
        // Only changes the key line, not the session.
        regrouped.allowWebForward = config.allowWebForward
        // Only read when opening VS Code (#288).
        regrouped.sshTarget = config.sshTarget
        if regrouped == config, let session {
            self.config = config
            session.setGroupSpacesByName(on: config.groupSpacesByName)
            return
        }
        // Another machine or server: its agents are not ours.
        if config.server != self.config.server { lastBoard = [] }
        self.config = config
        update = nil
        start()
    }

    /// Changes the order of spaces; the running session sends a rebuilt
    /// update at once, without reconnecting.
    func setSpaceSort(_ mode: SpaceSortMode, order: [String]?) {
        config.spaceSort = mode
        config.spaceOrder = order
        session?.setSpaceSort(sort: config.spaceSorting)
    }

    func followPane(_ paneID: String, live: Bool = true, observer: PaneObserver) -> PaneFollow? {
        session?.followPanePaced(paneId: paneID, live: live, observer: observer)
    }

    /// Sends a prompt to an agent, or text plus Enter to a shell.
    func submit(_ text: String, to paneID: String, isAgent: Bool) async throws {
        let session = try writableSession()
        try await Task.detached {
            if isAgent {
                try session.sendPrompt(paneId: paneID, text: text)
            } else {
                try session.sendText(paneId: paneID, text: text)
                try session.sendKeys(paneId: paneID, keys: ["enter"])
            }
        }.value
    }

    /// Creates a space with a shell in `directory` (`~` allowed).
    func createSpace(label: String, directory: String) async throws -> Created {
        let session = try writableSession()
        let cwd = absolutePath(directory)
        let name = label.trimmingCharacters(in: .whitespaces)
        return try await Task.detached {
            try session.createWorkspace(label: name.isEmpty ? nil : name, cwd: cwd)
        }.value
    }

    /// Creates a tab in a space; herdr picks the directory.
    func createTab(in workspaceID: String) async throws -> Created {
        let session = try writableSession()
        return try await Task.detached {
            try session.createTab(workspaceId: workspaceID, cwd: nil)
        }.value
    }

    /// Creates a Git worktree from the repository of a space and opens it
    /// as a new space. Empty fields are left to herdr: a generated branch,
    /// `HEAD` as base, the branch as name, herdr's worktree directory.
    func createWorktree(from workspaceID: String, branch: String, base: String, label: String) async throws -> Created {
        let session = try writableSession()
        let filled = { (value: String) -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let worktree = NewWorktree(branch: filled(branch), base: filled(base), label: filled(label), path: nil)
        return try await Task.detached {
            try session.createWorktree(workspaceId: workspaceID, worktree: worktree)
        }.value
    }

    /// Starts an agent of `kind` (e.g. `claude`) in a pane at its shell
    /// prompt and returns the agent's name. The agent comes up in the
    /// background; its state arrives with the next updates.
    func startAgent(kind: String, in paneID: String) async throws -> String {
        let session = try writableSession()
        return try await Task.detached {
            try session.startAgent(paneId: paneID, kind: kind, name: nil)
        }.value
    }

    /// Agent kinds the host can start, the usual ones first. Asked once per
    /// connection; herdr's list only changes with a new herdr version.
    func agentKinds() async -> [String] {
        if let cachedAgentKinds { return cachedAgentKinds }
        guard let session else { return [] }
        let kinds = await Task.detached { session.agentKinds() }.value
        cachedAgentKinds = kinds
        return kinds
    }

    @ObservationIgnored private var cachedAgentKinds: [String]?

    func renameSpace(_ workspaceID: String, to label: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.renameWorkspace(workspaceId: workspaceID, label: label)
        }.value
    }

    func renameTab(_ tabID: String, to label: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.renameTab(tabId: tabID, label: label)
        }.value
    }

    func closeTab(_ tabID: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.closeTab(tabId: tabID)
        }.value
    }

    func closeSpace(_ workspaceID: String, withWorktrees: Bool) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.closeWorkspace(workspaceId: workspaceID, withWorktrees: withWorktrees)
        }.value
    }

    /// An empty name removes the agent's name.
    func renameAgent(in paneID: String, to name: String) async throws {
        let session = try writableSession()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        try await Task.detached {
            try session.renameAgent(paneId: paneID, name: trimmed.isEmpty ? nil : trimmed)
        }.value
    }

    /// herdr does not expand `~` and silently falls back to the home
    /// directory for paths it cannot use, so the app sends absolute paths.
    /// Remote hosts are assumed to be Macs (`/Users/<user>`), as for the
    /// default socket path.
    func absolutePath(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let home = config.kind == .local
            ? (Platform.localSocketPath as NSString).deletingLastPathComponent
                .replacingOccurrences(of: "/.config/herdr", with: "")
            : "/Users/\(config.user)"
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + trimmed.dropFirst(1) }
        if trimmed.hasPrefix("/") { return trimmed }
        return home + "/" + trimmed
    }

    /// Uploads images and returns their paths on the host, in order. A file
    /// already on the host (#271) gives its path without an upload.
    func upload(_ attachments: [ImageAttachment]) async throws -> [String] {
        guard config.uploadAllowed else { throw ConnectionFailure.uploadOff }
        let session = try writableSession()
        // Before any upload, so a refused path leaves nothing behind.
        guard attachments.allSatisfy({ $0.hostPath.map(ImageAttachment.isPlainPath) ?? true }) else {
            throw ConnectionFailure.unsafePath
        }
        return try await Task.detached {
            try attachments.map { attachment in
                if let path = attachment.hostPath {
                    path
                } else if let name = attachment.fileName {
                    try session.uploadNamedFile(data: attachment.data, fileName: name)
                } else {
                    try session.uploadFile(data: attachment.data, fileExtension: attachment.fileExtension)
                }
            }
        }.value
    }

    /// The Claude Code conversation in a pane from its session file on the
    /// host, newest part first; `before` continues backwards. Read only, but
    /// over SSH it needs the same SFTP access as uploads.
    func claudeHistory(paneID: String, before: TranscriptCursor? = nil) async throws -> TranscriptPage {
        guard config.uploadAllowed else { throw ConnectionFailure.filesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return try await Task.detached {
            try session.claudeHistory(paneId: paneID, before: before)
        }.value
    }

    /// Token usage of Claude Code in the working directories `cwds` since
    /// `since` (#302). Read only, but over SSH it needs the same SFTP access
    /// as uploads; the first time a large read.
    func usage(cwds: [String], since: Date) async throws -> UsageReport {
        guard config.uploadAllowed else { throw ConnectionFailure.usageFilesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        let sinceSecs = UInt64(max(0, since.timeIntervalSince1970))
        return try await Task.detached {
            try session.usage(cwds: cwds, sinceSecs: sinceSecs)
        }.value
    }

    /// What `usage` has read in this session, to keep between runs.
    func usageState() async -> String? {
        guard let session else { return nil }
        return await Task.detached { session.usageState() }.value
    }

    /// Gives a new session what an earlier one had read.
    func restoreUsageState(_ state: String) async {
        guard let session else { return }
        await Task.detached { session.restoreUsageState(state: state) }.value
    }

    /// The last `lines` rows of a pane including scrollback as plain text,
    /// joined where the terminal wrapped them with `unwrap` (#273). Read
    /// only, a plain terminal read without file access.
    func recentText(paneID: String, lines: UInt32, unwrap: Bool) async throws -> String {
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return try await Task.detached {
            try session.recentText(paneId: paneID, maxLines: lines, unwrap: unwrap)
        }.value
    }

    /// What changed in a pane's working directory (#228). Read only, but it
    /// opens a short-lived tab to run Git and reads the result over SFTP, so
    /// it needs both input and file access.
    func workingTreeDiff(paneID: String) async throws -> WorkingTreeDiff {
        guard config.inputAllowed else { throw ConnectionFailure.readOnly }
        guard config.uploadAllowed else { throw ConnectionFailure.diffFilesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return try await Task.detached {
            try session.workingTreeDiff(paneId: paneID)
        }.value
    }

    /// The directory at the absolute `path` on the host, `""` for the home
    /// directory (#259). Read only, so no input needed, but over SSH it
    /// needs the same SFTP access as uploads.
    func listDirectory(_ path: String) async throws -> Directory {
        let session = try browseSession()
        return try await Task.detached {
            try session.listDirectory(path: path)
        }.value
    }

    /// The working directory of a pane for the file browser (#259), the
    /// home directory when it is unknown or outside the home.
    func openPaneDirectory(paneID: String) async throws -> Directory {
        let session = try browseSession()
        return try await Task.detached {
            try session.openPaneDirectory(paneId: paneID)
        }.value
    }

    /// The file at the absolute `path` to show in the file browser (#259).
    func filePreview(_ path: String) async throws -> FilePreview {
        let session = try browseSession()
        return try await Task.detached {
            try session.filePreview(path: path)
        }.value
    }

    /// Writes `text` to a file of the file browser (#271), unless it changed
    /// on the host since `preview` was read (`FfiError.FileChanged`); returns
    /// the file as now saved. Changes the host, so it needs input allowed
    /// besides the file access.
    func saveFile(_ preview: FilePreview, text: String) async throws -> FilePreview {
        guard config.inputAllowed else { throw ConnectionFailure.readOnly }
        let session = try browseSession()
        return try await Task.detached {
            try session.saveFile(path: preview.path, text: text, size: preview.size, modified: preview.modified)
        }.value
    }

    /// The names of the secrets on the host (#291), never their values.
    /// Over SSH it needs the same SFTP access as uploads.
    func secretNames() async throws -> [String] {
        let session = try secretsSession()
        return try await Task.detached {
            try session.secretNames()
        }.value
    }

    /// Writes a secret to `~/.amiscara-agents/env` on the host (#291).
    func sendSecret(name: String, value: String) async throws {
        let session = try secretsSession()
        try await Task.detached {
            try session.sendSecret(name: name, value: value)
        }.value
    }

    /// Deletes a secret on the host; a missing one is no error.
    func removeSecret(name: String) async throws {
        let session = try secretsSession()
        try await Task.detached {
            try session.removeSecret(name: name)
        }.value
    }

    /// The named herdr sessions on the host, running or stopped (#213).
    /// Read only, but over SSH it needs the same SFTP access as uploads.
    func herdrSessions() async throws -> [HerdrSession] {
        if config.kind == .local {
            return try await Task.detached { try localHerdrSessions() }.value
        }
        guard config.uploadAllowed else { throw ConnectionFailure.filesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return try await Task.detached {
            try session.herdrSessions()
        }.value
    }

    /// The transcript of a full-screen agent such as Claude Code (#187).
    /// herdr collects it by scrolling the idle agent on the host and back,
    /// so it needs input allowed like sending keys.
    func agentHistory(paneID: String) async throws -> PaneContent {
        let session = try writableSession()
        return try await Task.detached {
            try session.agentHistory(paneId: paneID)
        }.value
    }

    /// Scrolls the view of a full-screen agent, on the host too (#187).
    func scrollAgent(_ step: ScrollStep, in paneID: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.scrollAgent(paneId: paneID, step: step)
        }.value
    }

    /// The last `lines` lines with text of a pane's screen (#156); `nil`
    /// when not connected or the pane cannot be read. Read only.
    func screenExcerpt(paneID: String, lines: UInt32) async -> String? {
        guard let session, isLive else { return nil }
        return try? await Task.detached {
            try session.screenExcerpt(paneId: paneID, maxLines: lines)
        }.value
    }

    /// The choice question an agent asks in a pane, for a notification's
    /// actions (#272); `nil` when there is none, when not connected or the
    /// pane cannot be read. Read only.
    func choiceQuestion(paneID: String) async -> ChoiceQuestion? {
        guard let session, isLive else { return nil }
        return try? await Task.detached {
            try session.choiceQuestion(paneId: paneID)
        }.value ?? nil
    }

    /// Lets another device's key in on this host (#127); false when it was
    /// there already. Needs SFTP like uploads.
    func authorizeDeviceKey(_ publicKey: String, comment: String) async throws -> Bool {
        guard config.uploadAllowed else { throw ConnectionFailure.uploadOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return try await Task.detached {
            try session.authorizeDeviceKey(publicOpenssh: publicKey, comment: comment)
        }.value
    }

    /// The address to open for a page an agent asked for (#247): a page on
    /// the host's `localhost` is forwarded through the connection to a
    /// port on this device, other URLs come back unchanged.
    func openAddress(for request: OpenRequest) async throws -> String {
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        let url = request.url
        return try await Task.detached {
            try session.openUrl(url: url)
        }.value
    }

    /// Takes an open request back on the host, so other devices stop
    /// offering it. Best effort: the request expires on its own. It writes
    /// to herdr, so not on a read-only host.
    func dismiss(_ request: OpenRequest) async {
        guard config.inputAllowed, let session else { return }
        let (paneID, requestID) = (request.paneId, request.requestId)
        try? await Task.detached {
            try session.dismissOpenRequest(paneId: paneID, requestId: requestID)
        }.value
    }

    /// Takes an editor request back on the host (#288), so other devices
    /// stop offering it and the host does not open VS Code itself. Best
    /// effort like `dismiss(_:)`.
    func dismiss(editor request: EditorRequest) async {
        guard config.inputAllowed, let session else { return }
        let (paneID, requestID) = (request.paneId, request.requestId)
        try? await Task.detached {
            try session.dismissEditorRequest(paneId: paneID, requestId: requestID)
        }.value
    }

    /// The VS Code address of a folder on this host (#288): over
    /// Remote-SSH to `config.editorTarget`, directly on this Mac.
    func editorURL(path: String) -> URL? {
        URL(string: vscodeUrl(target: config.editorTarget, path: path))
    }

    /// A pane's working directory, for "In VS Code öffnen" (#288).
    func paneFolder(_ paneID: String) async -> String? {
        guard let session else { return nil }
        return await Task.detached { session.paneFolder(paneId: paneID) }.value
    }

    /// The working directory of a space's focused pane, for "In VS Code
    /// öffnen" (#288).
    func spaceFolder(_ workspaceID: String) async -> String? {
        guard let session else { return nil }
        return await Task.detached { session.spaceFolder(workspaceId: workspaceID) }.value
    }

    /// Types text into a pane without Enter.
    func send(text: String, to paneID: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.sendText(paneId: paneID, text: text)
        }.value
    }

    /// Sends logical keys such as `enter`, `esc`, `1` or `ctrl+c`.
    func send(keys: [String], to paneID: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.sendKeys(paneId: paneID, keys: keys)
        }.value
    }

    /// The session for the file browser (#259): file access, no input.
    private func browseSession() throws -> HostSession {
        guard config.uploadAllowed else { throw ConnectionFailure.browseFilesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return session
    }

    /// Secrets change the host, so they need input allowed besides the
    /// file access.
    private func secretsSession() throws -> HostSession {
        guard config.inputAllowed else { throw ConnectionFailure.readOnly }
        guard config.uploadAllowed else { throw ConnectionFailure.secretsFilesOff }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return session
    }

    private func writableSession() throws -> HostSession {
        guard config.inputAllowed else { throw ConnectionFailure.readOnly }
        guard let session, isLive else { throw ConnectionFailure.notConnected }
        return session
    }

    private func endpoint() throws -> Endpoint {
        switch config.kind {
        case .local:
            return .local(socketPath: config.socketPath.isEmpty ? nil : config.socketPath)
        case .ssh:
            guard let key = try KeyStore.load(for: config.id) else {
                throw ConnectionFailure.missingKey
            }
            let socket = config.socketPath.isEmpty
                ? defaultRemoteSocket(user: config.user)
                : config.socketPath
            return .ssh(
                host: config.host,
                port: UInt16(clamping: config.port),
                user: config.user,
                privateKeyOpenssh: key,
                pinnedHostKey: config.pinnedHostKey,
                socketPath: socket
            )
        }
    }
}

enum ConnectionFailure: LocalizedError {
    case missingKey
    case readOnly
    case notConnected
    case uploadOff
    case filesOff
    case diffFilesOff
    case browseFilesOff
    case secretsFilesOff
    case usageFilesOff
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "Für diesen Host liegt kein Schlüssel in der Keychain.")
        case .readOnly:
            String(localized: "Eingaben sind für diesen Host ausgeschaltet.")
        case .notConnected:
            String(localized: "Keine Verbindung zum Host.")
        case .uploadOff:
            String(localized: "Bilder hochladen ist für diesen Host ausgeschaltet (Host bearbeiten).")
        case .diffFilesOff:
            String(localized: "Die Änderungen liest die App über den Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
        case .browseFilesOff:
            String(localized: "Der Dateibrowser liest über den Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
        case .secretsFilesOff:
            String(localized: "Geheimnisse schreibt die App über den Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
        case .usageFilesOff:
            String(localized: "Die Tokens liest die App aus den Sitzungsdateien auf dem Host und braucht dafür Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
        case .unsafePath:
            String(localized: "Der Pfad enthält Steuerzeichen und kann nicht in einen Prompt.")
        case .filesOff:
            String(localized: "Der Gesprächsverlauf liest die Sitzungsdatei auf dem Host und braucht dafür Dateizugriff wie „Bilder hochladen“ (Host bearbeiten).")
        }
    }
}

/// Text for an error from sending input, in the app's language.
func inputErrorMessage(_ error: Error) -> String {
    switch error {
    case FfiError.AgentBlocked:
        String(localized: "Der Agent wartet auf eine Antwort. Bitte zuerst beantworten.")
    case FfiError.NotConnected:
        String(localized: "Keine Verbindung zum Host.")
    case FfiError.Upload(let message):
        String(localized: "Hochladen fehlgeschlagen: \(message)")
    case FfiError.Files(let message):
        String(localized: "Dateien auf dem Host nicht lesbar: \(message)")
    case FfiError.AgentWorking:
        String(localized: "Der Agent arbeitet gerade. Den Verlauf gibt es, sobald er fertig ist; blättern geht schon jetzt.")
    case FfiError.SavedNotRead:
        String(localized: "Gesichert, aber nicht neu gelesen. Vor dem nächsten Sichern die Datei neu laden.")
    case FfiError.FileChanged:
        String(localized: "Die Datei wurde auf dem Host geändert, seit sie geöffnet wurde. Nicht gesichert.")
    case FfiError.Forward:
        String(localized: "Der Host leitet localhost für dieses Gerät nicht weiter. „Lokale Webseiten weiterleiten“ einschalten (Host bearbeiten) und die neue Schlüsselzeile auf dem Host eintragen.")
    default:
        error.localizedDescription
    }
}

/// Text for an error from starting an agent. herdr's codes travel in the
/// message of `FfiError.Rejected`.
func agentStartErrorMessage(_ error: Error) -> String {
    let reason: String
    if case FfiError.Rejected(let message) = error {
        if message.contains("(agent_pane_busy)") {
            reason = String(localized: "Im Pane läuft schon ein Programm. Ein Agent startet nur an der Shell-Eingabe.")
        } else if message.contains("(unsupported_agent_kind)") {
            reason = String(localized: "herdr kennt diesen Agent nicht.")
        } else if message.contains("(agent_name_taken)") {
            reason = String(localized: "Es gibt schon zu viele Agents mit diesem Namen.")
        } else {
            reason = message
        }
    } else {
        reason = inputErrorMessage(error)
    }
    return String(localized: "Der Agent wurde nicht gestartet: \(reason)")
}

/// Forwards session updates from the Rust runtime.
final class SessionBridge: SessionObserver {
    private let handler: @Sendable (SessionUpdate) -> Void

    init(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        self.handler = handler
    }

    func onUpdate(update: SessionUpdate) {
        handler(update)
    }
}

private extension HostConfig {
    /// What identifies the herdr server behind an entry.
    var server: [String?] {
        [kind.rawValue, host, String(port), user, socketPath, pinnedHostKey]
    }
}
