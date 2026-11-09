import SwiftUI

#if !os(tvOS)
/// The herdr-core terminals a pane's text can link to (#331): addresses
/// such as `t7` or `vps/t7` that agents print when they start helpers.
/// Only live terminals of the host become links, and not the pane's own.
struct TerminalLinks {
    static let scheme = "amiscara-terminal"

    let hostID: UUID
    let viewingPaneID: String
    /// herdr-core pane ids of the host, with their workspace.
    private let workspaces: [String: String]

    @MainActor
    init(connection: HostConnection, viewingPaneID: String) {
        hostID = connection.id
        self.viewingPaneID = viewingPaneID
        var workspaces: [String: String] = [:]
        for workspace in connection.update?.workspaces ?? [] {
            for pane in workspace.tabs.flatMap(\.panes) where pane.paneId.hasPrefix("hc:") {
                workspaces[pane.paneId] = workspace.workspaceId
            }
        }
        self.workspaces = workspaces
    }

    /// The peek for an address as written; `nil` when no such terminal
    /// lives or it is the pane itself.
    @MainActor
    func peek(for address: String) -> AgentPeek? {
        let paneID = Self.paneID(address, from: viewingPaneID)
        guard paneID != viewingPaneID, let workspaceID = workspaces[paneID] else { return nil }
        return AgentPeek(hostID: hostID, workspaceID: workspaceID, paneID: paneID)
    }

    /// Resolved addresses, so a redraw does not call into Rust for every
    /// address again. The answer depends on nothing else.
    @MainActor private static var resolved: [String: String] = [:]

    @MainActor
    private static func paneID(_ address: String, from viewingPaneID: String) -> String {
        let key = "\(viewingPaneID)\u{0}\(address)"
        if let paneID = resolved[key] { return paneID }
        if resolved.count >= 1000 { resolved.removeAll() }
        let paneID = terminalPaneId(address: address, fromPaneId: viewingPaneID)
        resolved[key] = paneID
        return paneID
    }

    /// The link put on an address in the text.
    static func url(for address: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "address", value: address)]
        return components.url
    }

    /// The address behind a link from `url(for:)`.
    static func address(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "address" }?.value
    }
}

/// Shows a terminal from an address in a pane. Equal to any other: each
/// place sets one that always does the same (it sets that place's peek), so
/// a new closure on every update need not redraw the panes below.
struct PeekTerminalAction: Equatable {
    let action: (AgentPeek) -> Void

    init(_ action: @escaping (AgentPeek) -> Void) {
        self.action = action
    }

    func callAsFunction(_ peek: AgentPeek) {
        action(peek)
    }

    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Without it, addresses in a pane stay plain text.
    @Entry var peekTerminal: PeekTerminalAction? = nil
}
#endif
