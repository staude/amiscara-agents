import SwiftUI

/// Adds or edits a host. For SSH hosts the app creates a key for this Mac,
/// keeps the private half in the Keychain and shows the line for
/// `authorized_keys` on the server.
struct HostEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var config: HostConfig
    @State private var newPrivateKey: String?
    @State private var error: String?
    private let isNew: Bool

    init(config: HostConfig) {
        _config = State(initialValue: config)
        isNew = config.name.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $config.name, prompt: Text("z. B. work"))
                if Platform.hasLocalSocket {
                    Picker("Verbindung", selection: $config.kind) {
                        Text("SSH").tag(HostConfig.Kind.ssh)
                        Text("Dieser Mac").tag(HostConfig.Kind.local)
                    }
                    .pickerStyle(.segmented)
                }

                if config.kind == .ssh {
                    Section("Server") {
                        TextField("Host", text: $config.host, prompt: Text("work.staude.internal"))
                            .technicalInput()
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                        TextField("Benutzer", text: $config.user)
                            .technicalInput()
                        TextField("Socket", text: $config.socketPath, prompt: Text(socketPlaceholder))
                            .technicalInput()
                    }
                    keySection
                } else {
                    Section("Socket") {
                        TextField("Pfad", text: $config.socketPath, prompt: Text(Platform.localSocketPath))
                            .technicalInput()
                    }
                }

                Section {
                    Toggle("Eingaben erlauben", isOn: $config.inputAllowed)
                } footer: {
                    Text("Ausgeschaltet zeigt die App diesen Host nur an und sendet keine Prompts oder Tasten.")
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Hinzufügen" : "Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 520)
        #endif
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            Toggle("Bilder hochladen (SFTP)", isOn: $config.uploadAllowed)
            if let publicKey = config.publicKey {
                let line = (try? authorizedKeysLine(publicOpenssh: publicKey, allowSftp: config.uploadAllowed)) ?? publicKey
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                HStack {
                    Button("Zeile kopieren", systemImage: "doc.on.doc") {
                        Platform.copy(line)
                    }
                    Spacer()
                    if let fingerprint = try? describePublicKeyFingerprint() {
                        Text(fingerprint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Schlüssel für diesen Mac erzeugen", systemImage: "key") { generateKey() }
            }
        } header: {
            Text("Schlüssel")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tragen Sie die Zeile in ~/.ssh/authorized_keys auf dem Server ein. Der Schlüssel startet damit keine Shell und keine Befehle. Weiterleitungen bleiben möglich, auch TCP über den Server. Schließen lässt sich das nur mit AllowTcpForwarding no in der sshd_config des Servers. Geht ein Gerät verloren, die Zeile sofort entfernen.")
                if config.uploadAllowed {
                    Text("Mit „Bilder hochladen“ läuft für diesen Schlüssel sftp-server. Er kann dann alle Dateien Ihres Benutzers lesen und schreiben, auch ~/.ssh/authorized_keys, und sich so selbst mehr Rechte geben. Nach dem Umschalten die Zeile auf dem Server ersetzen.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var socketPlaceholder: String {
        config.user.isEmpty ? "/Users/<benutzer>/.config/herdr/herdr.sock" : defaultRemoteSocket(user: config.user)
    }

    private var isComplete: Bool {
        guard !config.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch config.kind {
        case .local: return true
        case .ssh: return !config.host.isEmpty && !config.user.isEmpty && config.publicKey != nil
        }
    }

    private func describePublicKeyFingerprint() throws -> String? {
        let stored = newPrivateKey == nil ? try KeyStore.load(for: config.id) : newPrivateKey
        guard let key = stored else { return nil }
        return try describeSshKey(privateOpenssh: key).fingerprint
    }

    private func generateKey() {
        do {
            let key = try generateSshKey(comment: "herdr-remote \(Platform.deviceName)")
            newPrivateKey = key.privateOpenssh
            config.publicKey = key.publicOpenssh
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            if config.kind == .ssh, let newPrivateKey {
                try KeyStore.save(privateKey: newPrivateKey, for: config.id)
            }
            if isNew {
                store.add(config)
            } else {
                store.update(config)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
