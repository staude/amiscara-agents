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
    @ObservationIgnored private var session: HostSession?
    /// Called on the main actor after every update, e.g. for notifications.
    @ObservationIgnored var onUpdate: ((HostConnection, SessionUpdate) -> Void)?
    nonisolated let id: UUID

    init(config: HostConfig) {
        self.config = config
        id = config.id
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
                    self.update = update
                    self.onUpdate?(self, update)
                }
            }
            session = try HostSession.start(endpoint: try endpoint(), observer: bridge)
        } catch {
            startError = error.localizedDescription
        }
    }

    func stop() {
        session?.stop()
        session = nil
        cachedAgentKinds = nil
    }

    /// Replaces the configuration (after editing or trusting a host key)
    /// and reconnects.
    func apply(_ config: HostConfig) {
        self.config = config
        update = nil
        start()
    }

    func followPane(_ paneID: String, observer: PaneObserver) -> PaneFollow? {
        session?.followPane(paneId: paneID, observer: observer)
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

    /// Uploads images and returns their paths on the host, in order.
    func upload(_ attachments: [ImageAttachment]) async throws -> [String] {
        guard config.uploadAllowed else { throw ConnectionFailure.uploadOff }
        let session = try writableSession()
        return try await Task.detached {
            try attachments.map { attachment in
                try session.uploadFile(data: attachment.data, fileExtension: attachment.fileExtension)
            }
        }.value
    }

    /// Sends logical keys such as `enter`, `esc`, `1` or `ctrl+c`.
    func send(keys: [String], to paneID: String) async throws {
        let session = try writableSession()
        try await Task.detached {
            try session.sendKeys(paneId: paneID, keys: keys)
        }.value
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
