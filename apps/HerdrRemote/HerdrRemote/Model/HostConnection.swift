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
                Task { @MainActor in self?.update = update }
            }
            session = try HostSession.start(endpoint: try endpoint(), observer: bridge)
        } catch {
            startError = error.localizedDescription
        }
    }

    func stop() {
        session?.stop()
        session = nil
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

    var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "Für diesen Host liegt kein Schlüssel in der Keychain.")
        }
    }
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
