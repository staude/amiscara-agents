import SwiftUI

/// Shows a host as a QR code (and link) for another device: host, port,
/// user, socket and the trusted host key. Scanned in Herdr Remote on iPhone
/// or iPad, it fills in the host editor with the key already pinned.
///
/// "Dieser Mac" has no SSH data of its own: the user enters the name other
/// devices reach this Mac under, the host key comes from sshd's key file.
struct HostQRView: View {
    @Environment(\.dismiss) private var dismiss
    let config: HostConfig
    /// Name of this Mac on the network, remembered for the next time.
    @AppStorage("qrLocalHostName") private var localHostName = ""
    @State private var localHostKey = ""
    @State private var localKeyUnreadable = false
    @State private var copied = false

    private enum Outcome {
        case link(String, fingerprint: String)
        case problem(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                if config.kind == .local {
                    localSection
                }
                switch outcome {
                case .link(let text, let fingerprint):
                    codeSection(text, fingerprint: fingerprint)
                case .problem(let message):
                    Section {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("QR-Code für \(config.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: config.kind == .local ? 700 : 600)
        #endif
        .onAppear {
            guard config.kind == .local, localHostKey.isEmpty else { return }
            if let key = Platform.localHostKey(), !key.isEmpty {
                localHostKey = key
            } else {
                localKeyUnreadable = true
            }
        }
    }

    @ViewBuilder
    private var localSection: some View {
        Section {
            TextField("Host", text: $localHostName, prompt: Text("work.staude.internal"))
                .technicalInput()
        } footer: {
            Text("Name oder IP-Adresse, unter der iPhone und iPad diesen Mac per SSH erreichen. Dafür muss in den Systemeinstellungen unter Allgemein > Teilen die entfernte Anmeldung eingeschaltet sein.")
        }
        if localKeyUnreadable {
            Section {
                TextField("Host-Key", text: $localHostKey, prompt: Text("ssh-ed25519 AAAA…"), axis: .vertical)
                    .technicalInput()
                    .font(.system(.caption, design: .monospaced))
            } header: {
                Text("Host-Key")
            } footer: {
                Text("/etc/ssh/ssh_host_ed25519_key.pub ließ sich nicht lesen. Fügen Sie die Zeile aus dieser Datei hier ein.")
            }
        }
    }

    private func codeSection(_ text: String, fingerprint: String) -> some View {
        Section {
            if let image = QRCode.image(for: text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    // Scanners need the light quiet zone, also in dark mode.
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR-Code zum Hinzufügen von \(config.name)")
            }
            LabeledContent("Host-Key", value: fingerprint)
                .font(.caption)
                .textSelection(.enabled)
            Button {
                Platform.copy(text)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copied = false }
                }
            } label: {
                Label(copied ? "Kopiert" : "Link kopieren", systemImage: copied ? "checkmark.circle.fill" : "link")
                    .contentTransition(.symbolEffect(.replace))
            }
        } footer: {
            Text("In Herdr Remote auf iPhone oder iPad unter „Host hinzufügen“ scannen. Danach die Schlüsselzeile des Geräts auf diesem Host in ~/.ssh/authorized_keys eintragen.")
        }
    }

    private var outcome: Outcome {
        let link: AddHostLink
        switch config.kind {
        case .ssh:
            guard let key = config.pinnedHostKey else {
                return .problem(String(localized: "Diesem Host ist noch kein Host-Key vertraut. Verbinden Sie sich einmal und bestätigen Sie den Fingerprint, dann gibt es hier den QR-Code."))
            }
            guard let port = UInt16(exactly: config.port) else {
                return .problem(String(localized: "Der Port dieses Hosts ist ungültig."))
            }
            link = AddHostLink(
                name: config.name,
                host: config.host.trimmingCharacters(in: .whitespaces),
                port: port,
                user: config.user.trimmingCharacters(in: .whitespaces),
                socketPath: config.socketPath.trimmingCharacters(in: .whitespaces),
                hostKey: key.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .local:
            let host = localHostName.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                return .problem(String(localized: "Tragen Sie oben ein, unter welchem Namen dieser Mac erreichbar ist."))
            }
            let key = localHostKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .problem(String(localized: "Es fehlt der Host-Key dieses Macs."))
            }
            let socket = config.socketPath.trimmingCharacters(in: .whitespaces)
            link = AddHostLink(
                name: Platform.deviceName,
                host: host,
                port: 22,
                user: Platform.userName,
                socketPath: socket.isEmpty ? Platform.localSocketPath : socket,
                hostKey: key
            )
        }
        do {
            let text = try encodeAddHostLink(link: link)
            let fingerprint = (try? publicKeyFingerprint(publicOpenssh: link.hostKey)) ?? ""
            return .link(text, fingerprint: fingerprint)
        } catch {
            return .problem(hostLinkErrorMessage(error))
        }
    }
}
