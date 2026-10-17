import SwiftUI

/// Adds or edits a host. For SSH hosts the app creates a key for this Mac,
/// keeps the private half in the Keychain and shows the line for
/// `authorized_keys` on the server.
struct HostEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var config: HostConfig
    private let original: HostConfig
    @State private var newPrivateKey: String?
    @State private var error: String?
    /// Set for a moment after "Zeile kopieren", so the tap visibly worked.
    @State private var copied = false
    private let isNew: Bool
    /// An "add host" link opened from outside, applied once on appear.
    private let importLink: String?
    @State private var scanning = false
    /// Why a scanned or pasted code was refused, shown next to the buttons.
    @State private var importError: String?

    init(config: HostConfig, importLink: String? = nil) {
        _config = State(initialValue: config)
        original = config
        isNew = config.name.isEmpty
        self.importLink = importLink
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
                    importSection
                    Section("Server") {
                        TextField("Host", text: $config.host, prompt: Text("work.staude.internal"))
                            .technicalInput()
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                        TextField("Benutzer", text: $config.user)
                            .technicalInput()
                        TextField("Socket", text: $config.socketPath, prompt: Text(socketPlaceholder))
                            .technicalInput()
                    }
                    hostKeySection
                    keySection
                } else {
                    Section("Socket") {
                        TextField("Pfad", text: $config.socketPath, prompt: Text(Platform.localSocketPath))
                            .technicalInput()
                    }
                }

                Section {
                    Toggle("Benachrichtigungen", isOn: $config.notificationsOn)
                } footer: {
                    Text("Mitteilung, wenn ein Agent auf eine Antwort wartet oder fertig ist. Auf iPad und iPhone nur, solange die App läuft.")
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
        // A swipe down would drop changes silently on iPad.
        .interactiveDismissDisabled(config != original || newPrivateKey != nil)
        .task {
            if let importLink { applyLink(importLink) }
        }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            QRScannerView { link in apply(link) }
        }
        #endif
    }

    /// Fill in everything from a code another device shows (its host menu,
    /// "QR-Code zeigen"): nothing to type, the host key is pinned at once.
    private var importSection: some View {
        Section {
            #if os(iOS)
            Button("QR-Code scannen", systemImage: "qrcode.viewfinder") { scanning = true }
            #endif
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in applyLink(text) }
            }
            if let importError {
                Text(importError).foregroundStyle(.red)
            }
        } header: {
            Text("Per QR-Code")
        } footer: {
            Text("Auf dem Mac in Herdr Remote im Menü des Hosts „QR-Code zeigen“ wählen. Statt zu scannen können Sie auch den dort kopierten Link einfügen.")
        }
    }

    @ViewBuilder
    private var hostKeySection: some View {
        if let key = config.pinnedHostKey {
            Section {
                LabeledContent("Host-Key", value: (try? publicKeyFingerprint(publicOpenssh: key)) ?? key)
                    .font(.caption)
                    .textSelection(.enabled)
            } footer: {
                Text("Diesem Schlüssel vertraut die App. Meldet sich der Server mit einem anderen, warnt sie.")
            }
        }
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
                    Button {
                        Platform.copy(line)
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(
                            copied ? "Kopiert" : "Zeile kopieren",
                            systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .foregroundStyle(copied ? .green : .accentColor)
                        .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.success, trigger: copied) { _, now in now }
                    .accessibilityHint(copied ? "In der Zwischenablage" : "")
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

    private func applyLink(_ text: String) {
        do {
            apply(try decodeAddHostLink(text: text))
        } catch {
            importError = hostLinkErrorMessage(error)
        }
    }

    private func apply(_ link: AddHostLink) {
        if let conflict = store.hostKeyConflict(for: link, editing: original) {
            importError = conflict
            return
        }
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty {
            config.name = link.name
        }
        config.kind = .ssh
        config.host = link.host
        config.port = Int(link.port)
        config.user = link.user
        // Keep the field empty for the default, like a host typed in by hand.
        config.socketPath = link.socketPath == defaultRemoteSocket(user: link.user) ? "" : link.socketPath
        config.pinnedHostKey = link.hostKey
        importError = nil
        // The authorized_keys line is the one step left; show it right away.
        if config.publicKey == nil {
            generateKey()
        }
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
