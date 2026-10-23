import SwiftUI

/// Another herdr session on a host the app knows (#213): lists the host's
/// sessions and hands a new host entry for the chosen one to the editor,
/// which creates a key of its own for it.
struct AddSessionView: View {
    let connection: HostConnection
    let onChoose: (HostConfig) -> Void
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [HerdrSession]?
    /// Why the list could not be read; the name can still be typed.
    @State private var loadError: String?
    @State private var typed = ""

    private var config: HostConfig { connection.config }

    var body: some View {
        NavigationStack {
            Form {
                if let sessions {
                    let offered = offered(sessions)
                    Section {
                        if offered.isEmpty {
                            Text("Für alle Sessions auf diesem Host gibt es schon einen Eintrag.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(offered, id: \.name) { session in
                            Button { choose(session.name) } label: {
                                LabeledContent(session.name.isEmpty ? String(localized: "Standard-Session") : session.name) {
                                    if !session.running {
                                        Text("gestoppt")
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Auch eine gestoppte Session lässt sich hinzufügen. Die App verbindet sich, sobald sie läuft.")
                    }
                } else if loadError == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                if let loadError {
                    Section {
                        TextField("Name der Session", text: $typed)
                            .technicalInput()
                            .onSubmit { if canChooseTyped { choose(typed) } }
                        Button("Weiter") { choose(typed) }
                            .disabled(!canChooseTyped)
                    } header: {
                        Text("Für die Liste braucht der Schlüssel SFTP (Bilder hochladen). Sie können den Namen auch eingeben.")
                    } footer: {
                        Text(loadError)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Weitere Session auf \(config.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private var canChooseTyped: Bool {
        let name = typed.trimmingCharacters(in: .whitespaces)
        return isValidSessionName(name: name) && !taken(socket(for: name))
    }

    private func load() async {
        if config.kind == .ssh && !config.uploadAllowed {
            loadError = String(localized: "Bilder hochladen ist für diesen Host ausgeschaltet.")
            return
        }
        do {
            sessions = try await connection.herdrSessions()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The default session first when the host is on another one, then the
    /// named sessions; none that already has an entry.
    private func offered(_ sessions: [HerdrSession]) -> [HerdrSession] {
        var all = sessions
        if !config.socketPath.isEmpty {
            all.insert(HerdrSession(name: "", running: true), at: 0)
        }
        return all.filter { !taken(socket(for: $0.name)) }
    }

    private var defaultSocket: String {
        config.kind == .local ? Platform.localSocketPath : defaultRemoteSocket(user: config.user)
    }

    /// The socket of session `name` on this host; empty for the default.
    private func socket(for name: String) -> String {
        let current = config.socketPath.isEmpty ? defaultSocket : config.socketPath
        guard let path = try? sessionSocketPath(defaultSocket: current, name: name) else { return "" }
        return path == defaultSocket ? "" : path
    }

    /// Whether a host entry already points at that socket on this machine.
    private func taken(_ socket: String) -> Bool {
        store.connections.contains { other in
            let host = other.config
            return host.kind == config.kind
                && HostStore.normalizedHost(host.host) == HostStore.normalizedHost(config.host)
                && host.port == config.port
                && host.user == config.user
                && host.socketPath == socket
        }
    }

    private func choose(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        var new = HostConfig(
            name: "\(config.name) (\(name.isEmpty ? String(localized: "Standard-Session") : name))",
            kind: config.kind
        )
        new.host = config.host
        new.port = config.port
        new.user = config.user
        new.socketPath = socket(for: name)
        new.pinnedHostKey = config.pinnedHostKey
        new.allowInput = config.allowInput
        new.notify = config.notify
        new.groupSpaces = config.groupSpaces
        onChoose(new)
        dismiss()
    }
}
