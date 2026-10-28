import SwiftUI

/// The Claude Code sessions of a space's folder (#304), newest first, to
/// continue one with `claude --resume` in a new tab of the space or in the
/// shown shell pane. A new shell has the current environment, which a pane
/// started before a change to the shell's startup files lacks.
struct ClaudeSessionsView: View {
    let target: ClaudeSessionsTarget
    let onCreated: (Created) -> Void
    @Environment(\.dismiss) private var dismiss
    /// `nil` while loading; also when the space reports no folder.
    @State private var folder: String?
    @State private var folderLoaded = false
    @State private var paneFolder: String?
    @State private var sessions: [ClaudeSessionItem]?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var busy = false

    private var connection: HostConnection { target.connection }
    private var workspaceID: String { target.workspaceID }
    /// The shown pane, offered when it is a shell in the same folder.
    private var paneID: String? { target.paneID }

    var body: some View {
        NavigationStack {
            Form {
                if folderLoaded && folder == nil {
                    Text("herdr kennt den Ordner dieses Space nicht.")
                        .foregroundStyle(.secondary)
                } else if let sessions, sessions.isEmpty {
                    ContentUnavailableView("Keine Sitzungen in diesem Ordner", systemImage: "clock.arrow.circlepath")
                } else {
                    Section {
                        ForEach(sessions ?? [], id: \.id) { session in
                            row(session)
                        }
                        if sessions == nil && loadError == nil {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    } header: {
                        if let folder {
                            Text(verbatim: folder)
                                .textCase(nil)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    } footer: {
                        if let loadError {
                            Text(loadError)
                        } else {
                            Text("Läuft eine Sitzung noch in einer anderen Pane, dort Claude vorher beenden: Sonst schreiben zwei Claude-Prozesse in dieselbe Sitzung.")
                        }
                    }
                }
                if let actionError {
                    Section {
                        Text(actionError)
                            .foregroundStyle(.red)
                            .selectableText()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Claude-Sitzungen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }

    @ViewBuilder
    private func row(_ session: ClaudeSessionItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(2)
                Text(details(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connection.config.inputAllowed {
                if canResumeHere {
                    Button("In dieser Pane fortsetzen", systemImage: "arrow.right.circle") { resumeHere(session) }
                        .labelStyle(.iconOnly)
                        .help(String(localized: "In dieser Pane fortsetzen"))
                }
                Button("In neuer Pane fortsetzen", systemImage: "plus.rectangle") { resumeInNewTab(session) }
                    .labelStyle(.iconOnly)
                    .help(String(localized: "In neuer Pane fortsetzen"))
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy)
    }

    private func details(_ session: ClaudeSessionItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: session.size), countStyle: .file)
        guard session.modified > 0 else { return size }
        let date = Date(timeIntervalSince1970: TimeInterval(session.modified))
        return "\(min(date, .now).formatted(.relative(presentation: .named))) · \(size)"
    }

    /// The shown pane is a shell in the list's folder: Claude Code finds a
    /// session only in the folder it ran in.
    private var canResumeHere: Bool {
        guard let paneID, let folder, paneFolder == folder else { return false }
        let pane = connection.update?.workspaces
            .flatMap(\.tabs)
            .flatMap(\.panes)
            .first { $0.paneId == paneID }
        return pane != nil && pane?.agent == nil
    }

    private func load() async {
        folder = await connection.spaceFolder(workspaceID)
        if let paneID {
            paneFolder = await connection.paneFolder(paneID)
        }
        folderLoaded = true
        guard let folder else { return }
        do {
            sessions = try await connection.claudeSessions(folder: folder)
        } catch {
            loadError = inputErrorMessage(error)
        }
    }

    private func resumeInNewTab(_ session: ClaudeSessionItem) {
        guard let folder else { return }
        busy = true
        actionError = nil
        Task {
            defer { busy = false }
            let created: Created
            do {
                created = try await connection.createTab(in: workspaceID, cwd: folder)
            } catch {
                actionError = inputErrorMessage(error)
                return
            }
            onCreated(created)
            do {
                _ = try await connection.resumeClaude(session.id, in: created.paneId)
            } catch {
                actionError = agentStartErrorMessage(error)
                return
            }
            dismiss()
        }
    }

    private func resumeHere(_ session: ClaudeSessionItem) {
        guard let paneID else { return }
        busy = true
        actionError = nil
        Task {
            defer { busy = false }
            do {
                _ = try await connection.resumeClaude(session.id, in: paneID)
            } catch {
                actionError = agentStartErrorMessage(error)
                return
            }
            dismiss()
        }
    }
}

/// What the Claude sessions sheet opens for: a space, and the pane shown
/// in it if any.
struct ClaudeSessionsTarget: Identifiable {
    let connection: HostConnection
    let workspaceID: String
    var paneID: String?

    var id: String { "\(connection.id.uuidString)/\(workspaceID)" }
}
