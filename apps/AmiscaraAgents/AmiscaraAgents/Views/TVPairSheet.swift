#if os(iOS)
import SwiftUI

/// The iPhone side of pairing an Apple TV (#127), opened by the TV's QR
/// code: lets the TV's key in on the chosen hosts and leaves their data for
/// the TV in iCloud.
struct TVPairSheet: View {
    let link: TVPairing.Link
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []
    @State private var working = false
    @State private var results: [UUID: String] = [:]
    @State private var done = false
    @State private var error: String?

    /// SSH hosts with a pinned key; writing the key needs SFTP and a session.
    private var hosts: [HostConnection] {
        store.connections.filter { $0.config.kind == .ssh && $0.config.pinnedHostKey != nil }
    }

    private func usable(_ connection: HostConnection) -> Bool {
        connection.config.uploadAllowed && connection.isLive
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Apple TV", value: link.name)
                    LabeledContent("Fingerabdruck", value: (try? publicKeyFingerprint(publicOpenssh: link.publicKey)) ?? "?")
                        .font(.caption.monospaced())
                } footer: {
                    Text("Vergleichen Sie den Fingerabdruck mit dem auf dem Fernseher.")
                }
                Section {
                    ForEach(hosts) { connection in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(connection.id) },
                            set: { if $0 { chosen.insert(connection.id) } else { chosen.remove(connection.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(connection.config.name)
                                if let result = results[connection.id] {
                                    Text(result).font(.caption).foregroundStyle(.secondary)
                                } else if !usable(connection) {
                                    Text(connection.isLive ? "Braucht „Bilder hochladen“ (Dateizugriff)" : "Nicht verbunden")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(!usable(connection) || working || done)
                    }
                } header: {
                    Text("Hosts für das Apple TV")
                } footer: {
                    Text("Auf jedem gewählten Host kommt diese Zeile in ~/.ssh/authorized_keys (die alte Datei bleibt als authorized_keys.bak-amiscara): nur Zugriff auf herdr, keine Shell, keine Dateien.")
                }
                if let line = try? authorizedKeysLine(publicOpenssh: link.publicKey, allowSftp: false) {
                    Section("Zeile") {
                        // As written by the core: without the key's own comment.
                        let name = String(link.name.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" })
                        Text(line.split(separator: " ").prefix(3).joined(separator: " ") + " amiscara-agents-" + name)
                            .font(.caption2.monospaced())
                            .selectableText()
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .navigationTitle("Apple TV koppeln")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "Fertig" : "Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if !done {
                        Button("Koppeln") { Task { await pair() } }
                            .disabled(chosen.isEmpty)
                    }
                }
            }
        }
    }

    private func pair() async {
        working = true
        defer { working = false }
        error = nil
        var paired: [TVPairing.Host] = []
        for connection in hosts where chosen.contains(connection.id) {
            do {
                let added = try await connection.authorizeDeviceKey(link.publicKey, comment: link.name)
                results[connection.id] = added ? String(localized: "Schlüssel eingetragen") : String(localized: "Schlüssel war schon eingetragen")
                let config = connection.config
                paired.append(TVPairing.Host(
                    name: config.name,
                    host: config.host,
                    port: config.port,
                    user: config.user,
                    socketPath: config.socketPath,
                    hostKey: config.pinnedHostKey ?? ""
                ))
            } catch {
                results[connection.id] = inputErrorMessage(error)
            }
        }
        guard !paired.isEmpty else { return }
        do {
            try await TVPairing.add(paired, for: link.tvID)
            done = true
        } catch {
            self.error = String(localized: "iCloud: \(error.localizedDescription)")
        }
    }
}
#endif
