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
    /// The herdr session as typed (#213); a valid name sets the socket path.
    @State private var sessionName = ""
    /// Sessions found on the host, offered next to the field.
    @State private var knownSessions: [HerdrSession] = []
    /// An "add host" link opened from outside, applied once on appear.
    private let importLink: String?
    @State private var scanning = false
    /// Why a scanned or pasted code was refused, shown next to the buttons.
    @State private var importError: String?
    /// Host key from a scanned or opened code. A link can come from any
    /// website or message, so the key stays unverified until the user
    /// confirms its fingerprint against the sending device; unconfirmed,
    /// the host is saved without a pinned key and the normal first-contact
    /// prompt applies.
    @State private var importedKey: ImportedKey?
    @State private var keyConfirmed = false
    #if !os(tvOS)
    /// The host's GitHub token on this device (#296); empty removes it.
    @State private var githubToken = ""
    @State private var originalGitHubToken = ""
    @State private var tokenLoaded = false
    #endif

    private struct ImportedKey: Equatable {
        let key: String
        let fingerprint: String
        /// The address the code named; editing it drops the key.
        let host: String
        let port: Int
    }

    init(config: HostConfig, importLink: String? = nil) {
        _config = State(initialValue: config)
        original = config
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
                    Section {
                        TextField("Host", text: $config.host, prompt: Text("mac.example.internal"))
                            .technicalInput()
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                        TextField("Benutzer", text: $config.user)
                            .technicalInput()
                        TextField("Socket", text: $config.socketPath, prompt: Text(socketPlaceholder))
                            .technicalInput()
                        sessionField
                        #if !os(tvOS)
                        Toggle("Über NetBird", isOn: Binding(
                            get: { config.behindNetBird },
                            set: { config.viaNetBird = $0 }
                        ))
                        #endif
                        #if os(macOS)
                        TextField("SSH-Ziel für VS Code", text: sshTarget, prompt: Text(verbatim: sshTargetPlaceholder))
                            .technicalInput()
                        #endif
                    } header: {
                        Text("Server")
                    } footer: {
                        #if !os(tvOS)
                        Text("NetBird-Adressen und -Domains erkennt die App selbst, eigene Domains lernt sie, sobald NetBird läuft. Mit dem Schalter lässt sich das überschreiben.")
                        #endif
                    }
                    importedKeySection
                    hostKeySection
                    keySection
                } else {
                    Section("Socket") {
                        TextField("Pfad", text: $config.socketPath, prompt: Text(Platform.localSocketPath))
                            .technicalInput()
                        sessionField
                    }
                }

                Section {
                    Toggle("Benachrichtigungen", isOn: $config.notificationsOn)
                } footer: {
                    Text("Mitteilung, wenn ein Agent auf eine Antwort wartet oder fertig ist. Auf iPad und iPhone kommen sie im Hintergrund über iCloud, wenn die Mac-App auf dem Host läuft.")
                }
                #if os(macOS)
                if config.kind == .local {
                    CloudPushSection(sender: store.cloudPush)
                }
                #elseif os(iOS)
                if let status = CloudPushSubscriptions.shared.status {
                    Section("Push über iCloud") {
                        Label(status, systemImage: CloudPushSubscriptions.shared.active ? "checkmark.icloud" : "exclamationmark.icloud")
                            .foregroundStyle(CloudPushSubscriptions.shared.active ? Color.secondary : Color.orange)
                            .selectableText()
                    }
                }
                #endif

                Section {
                    Toggle("Spaces nach Namen gruppieren", isOn: $config.groupSpacesByName)
                } footer: {
                    Text("Ein Space namens „Bereich/Name“ erscheint als „Name“ in der Gruppe „Bereich“. Ausgeschaltet zeigt die App alle Spaces mit vollem Namen in der Reihenfolge von herdr.")
                }

                Section {
                    Toggle("Eingaben erlauben", isOn: $config.inputAllowed)
                } footer: {
                    Text("Ausgeschaltet zeigt die App diesen Host nur an und sendet keine Prompts oder Tasten.")
                }

                #if !os(tvOS)
                Section {
                    SecureField("Token", text: $githubToken, prompt: Text(verbatim: "github_pat_…"))
                        .technicalInput()
                    if let tokenError = store.connection(for: original.id)?.pullRequests.tokenError, !githubTokenChanged {
                        Label(tokenError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(verbatim: "GitHub")
                } footer: {
                    Text("Mit einem Token zeigen Übersicht und Dashboard unter „Freigaben“ die Pläne, die in den Repos dieses Hosts auf Freigabe warten, und jeder Space den offenen Pull Request seines Branches, den die App auch mergt. Ein Fine-grained Token mit Lesezugriff auf Issues, Checks, Commit statuses und Metadata sowie Lese- und Schreibzugriff auf Contents und Pull requests; für die Freigaben allein genügt Issues: Read. Er liegt nur im Schlüsselbund dieses Geräts; leer entfernt ihn. Die Repos liest die App über den Dateizugriff wie „Bilder hochladen“.")
                }
                #endif

                if let error {
                    Text(error).foregroundStyle(.red).selectableText()
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    #if !os(tvOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
                Button(isNew ? "Hinzufügen" : "Sichern") { save() }
                    #if !os(tvOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                    .disabled(!isComplete)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 520)
        #endif
        // A swipe down would drop changes silently on iPad.
        .interactiveDismissDisabled(config != original || newPrivateKey != nil || importedKey != nil || githubTokenChanged)
        .onChange(of: config.host) { dropImportedKeyIfAddressChanged() }
        .onChange(of: config.port) { dropImportedKeyIfAddressChanged() }
        .onChange(of: config.socketPath, initial: true) { showSessionOfSocket() }
        .onChange(of: config.user) { old, new in followUser(from: old, to: new) }
        .onChange(of: sessionName) { applySessionName() }
        .task {
            if let importLink {
                applyLink(importLink)
            } else if isNew, config.kind == .ssh, !config.host.isEmpty, config.publicKey == nil {
                // A further session of a known host (#213): its own key,
                // because a key line serves exactly one socket.
                generateKey()
            }
        }
        .task(id: config.kind) { await loadSessions() }
        #if !os(tvOS)
        // Once per sheet, not with every new value of the view.
        .onAppear {
            guard !tokenLoaded else { return }
            tokenLoaded = true
            let token = ((try? GitHubToken.load(for: original.id)) ?? nil) ?? ""
            githubToken = token
            originalGitHubToken = token
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            QRScannerView { link in apply(link) }
        }
        #endif
    }

    /// Fill in everything from a code another device shows (its host menu,
    /// "QR-Code zeigen"): nothing to type; the host key is pinned once its
    /// fingerprint is confirmed.
    private var importSection: some View {
        Section {
            #if os(iOS)
            Button("QR-Code scannen", systemImage: "qrcode.viewfinder") { scanning = true }
            #endif
            #if !os(tvOS)
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in applyLink(text) }
            }
            #endif
            if let importError {
                Text(importError).foregroundStyle(.red)
            }
        } header: {
            Text("Per QR-Code")
        } footer: {
            Text("Auf dem Mac in Amiscara Agents im Menü des Hosts „QR-Code zeigen“ wählen. Statt zu scannen können Sie auch den dort kopierten Link einfügen.")
        }
    }

    @ViewBuilder
    private var importedKeySection: some View {
        if let importedKey {
            Section {
                LabeledContent("Fingerabdruck", value: importedKey.fingerprint)
                    .font(.caption.monospaced())
                    .selectableText()
                Toggle("Fingerabdruck stimmt mit dem auf dem Mac angezeigten überein", isOn: $keyConfirmed)
            } header: {
                Text("Host-Key aus dem Code (ungeprüft)")
            } footer: {
                Text("Vergleichen Sie den Fingerabdruck mit dem, den das andere Gerät unter dem QR-Code zeigt. Ohne Bestätigung wird kein Host-Key gespeichert und die App fragt beim ersten Verbinden nach.")
            }
        }
    }

    @ViewBuilder
    private var hostKeySection: some View {
        if let key = config.pinnedHostKey {
            Section {
                LabeledContent("Host-Key", value: (try? publicKeyFingerprint(publicOpenssh: key)) ?? key)
                    .font(.caption)
                    .selectableText()
            } footer: {
                Text("Diesem Schlüssel vertraut die App. Meldet sich der Server mit einem anderen, warnt sie.")
            }
        }
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            Toggle("Bilder hochladen (SFTP)", isOn: $config.uploadAllowed)
            #if !os(tvOS)
            Toggle("Lokale Webseiten weiterleiten", isOn: $config.webForwardAllowed)
            #endif
            if let publicKey = config.publicKey {
                let line = (try? authorizedKeysLine(publicOpenssh: publicKey, allowSftp: config.uploadAllowed, allowWeb: config.webForwardAllowed, socketPath: config.socketPath.isEmpty ? nil : config.socketPath)) ?? publicKey
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .selectableText()
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
                if config.webForwardAllowed {
                    Text("Mit „Lokale Webseiten weiterleiten“ erreicht der Schlüssel zusätzlich Ports unter localhost auf dem Server, damit Seiten, die ein Agent dort öffnet, auch hier laden. Nach dem Umschalten die Zeile auf dem Server ersetzen.")
                }
            }
        }
    }

    /// The herdr session by name instead of its socket path (#213), with
    /// the host's sessions to pick from when they are known.
    private var sessionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Session", text: $sessionName, prompt: Text("Standard-Session"))
                    .technicalInput()
                    .disabled(defaultSocket == nil)
                if !knownSessions.isEmpty {
                    Menu {
                        Button("Standard-Session") { sessionName = "" }
                        ForEach(knownSessions, id: \.name) { session in
                            Button(session.running ? session.name : String(localized: "\(session.name) (gestoppt)")) {
                                sessionName = session.name
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Sessions auf dem Host")
                }
            }
            if sessionNameInvalid {
                Text("Erlaubt sind Buchstaben, Ziffern, „-“, „_“ und „.“, nicht am Anfang.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The host's default `herdr.sock`; `nil` while the SSH user is missing.
    private var defaultSocket: String? {
        switch config.kind {
        case .local: Platform.localSocketPath.isEmpty ? nil : Platform.localSocketPath
        case .ssh: config.user.isEmpty ? nil : defaultRemoteSocket(user: config.user)
        }
    }

    private var sessionNameInvalid: Bool {
        let name = sessionName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !isValidSessionName(name: name)
    }

    private func showSessionOfSocket() {
        let socket = config.socketPath.isEmpty ? (defaultSocket ?? "") : config.socketPath
        let name = sessionNameOfSocket(socketPath: socket) ?? ""
        // Only when it differs, so typing is not overwritten mid-word.
        if name != sessionName.trimmingCharacters(in: .whitespaces) && !sessionNameInvalid {
            sessionName = name
        }
    }

    private func applySessionName() {
        guard !sessionNameInvalid, let defaultSocket else { return }
        let current = config.socketPath.isEmpty ? defaultSocket : config.socketPath
        guard let path = try? sessionSocketPath(defaultSocket: current, name: sessionName) else { return }
        // Keep the field empty for the default, like a host typed in by hand.
        let next = path == defaultSocket ? "" : path
        if next != config.socketPath { config.socketPath = next }
    }

    /// A session socket built for the previous user moves to the new one.
    private func followUser(from old: String, to new: String) {
        guard config.kind == .ssh, !old.isEmpty, !new.isEmpty,
              config.socketPath.hasPrefix("/Users/\(old)/.config/herdr/"),
              let name = sessionNameOfSocket(socketPath: config.socketPath),
              let path = try? sessionSocketPath(defaultSocket: defaultRemoteSocket(user: new), name: name)
        else { return }
        config.socketPath = path
    }

    /// This Mac's sessions, or those of a known host whose key may read
    /// files; others have to be typed.
    private func loadSessions() async {
        if config.kind == .local {
            knownSessions = (try? await Task.detached { try localHerdrSessions() }.value) ?? []
        } else if let connection = store.connection(for: config.id), connection.config.kind == .ssh,
                  connection.config.uploadAllowed, connection.isLive {
            knownSessions = (try? await connection.herdrSessions()) ?? []
        } else {
            knownSessions = []
        }
    }

    #if os(macOS)
    /// The SSH target for VS Code (#288); empty stores nil, so the default
    /// follows user and host.
    private var sshTarget: Binding<String> {
        Binding {
            config.sshTarget ?? ""
        } set: {
            let target = $0.trimmingCharacters(in: .whitespaces)
            config.sshTarget = target.isEmpty ? nil : target
        }
    }

    private var sshTargetPlaceholder: String {
        config.user.isEmpty || config.host.isEmpty ? "user@host" : "\(config.user)@\(config.host)"
    }
    #endif

    private var socketPlaceholder: String {
        config.user.isEmpty ? String(localized: "/Users/<benutzer>/.config/herdr/herdr.sock") : defaultRemoteSocket(user: config.user)
    }

    private var githubTokenChanged: Bool {
        #if os(tvOS)
        false
        #else
        githubToken != originalGitHubToken
        #endif
    }

    /// Not yet in the store: a new host, also one handed over prefilled.
    private var isNew: Bool {
        store.connection(for: original.id) == nil
    }

    private var isComplete: Bool {
        guard !config.name.trimmingCharacters(in: .whitespaces).isEmpty, !sessionNameInvalid else { return false }
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
        if let conflict = store.hostKeyConflict(host: link.host, port: Int(link.port), key: link.hostKey, editing: original) {
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
        if let pinned = original.pinnedHostKey, HostStore.sameKey(pinned, link.hostKey) {
            // Already trusted; nothing to confirm.
            importedKey = nil
        } else {
            importedKey = ImportedKey(
                key: link.hostKey,
                fingerprint: (try? publicKeyFingerprint(publicOpenssh: link.hostKey)) ?? link.hostKey,
                host: HostStore.normalizedHost(link.host),
                port: Int(link.port)
            )
        }
        keyConfirmed = false
        importError = nil
        // The authorized_keys line is the one step left; show it right away.
        if config.publicKey == nil {
            generateKey()
        }
    }

    private func dropImportedKeyIfAddressChanged() {
        guard let importedKey else { return }
        if HostStore.normalizedHost(config.host) != importedKey.host || config.port != importedKey.port {
            self.importedKey = nil
            keyConfirmed = false
            importError = String(localized: "Host oder Port wurden geändert. Der Host-Key aus dem Code wurde verworfen.")
        }
    }

    private func generateKey() {
        do {
            let key = try generateSshKey(comment: "amiscara-agents \(Platform.deviceName)")
            newPrivateKey = key.privateOpenssh
            config.publicKey = key.publicOpenssh
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        var config = config
        if config.kind == .ssh, let importedKey, keyConfirmed,
           HostStore.normalizedHost(config.host) == importedKey.host, config.port == importedKey.port {
            // Re-checked: another host may have been trusted meanwhile.
            if let conflict = store.hostKeyConflict(host: config.host, port: config.port, key: importedKey.key, editing: original) {
                error = conflict
                return
            }
            config.pinnedHostKey = importedKey.key
        }
        do {
            if config.kind == .ssh, let newPrivateKey {
                try KeyStore.save(privateKey: newPrivateKey, for: config.id)
            }
            #if !os(tvOS)
            if githubTokenChanged {
                let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.isEmpty {
                    GitHubToken.delete(for: config.id)
                } else {
                    try GitHubToken.save(token, for: config.id)
                }
                store.approvals.reset(config.id)
                let approvals = store.approvals
                let connections = store.connections
                Task { await approvals.load(connections, force: true) }
            }
            #endif
            if isNew {
                store.add(config)
            } else {
                store.update(config)
            }
            #if !os(tvOS)
            if githubTokenChanged {
                store.connection(for: config.id)?.pullRequests.tokenChanged()
            }
            #endif
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
