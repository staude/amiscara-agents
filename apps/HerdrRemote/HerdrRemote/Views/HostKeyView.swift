import SwiftUI

/// Asks before trusting a server's host key: on first contact, and loudly
/// when a trusted key changed.
struct HostKeyView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let connection: HostConnection
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch connection.status {
            case .hostKeyUnknown(let key, let fingerprint):
                Label("Unbekannter Host-Key", systemImage: "key")
                    .font(.title3.weight(.semibold))
                Text("\(connection.config.name) (\(connection.config.host)) meldet sich mit diesem Schlüssel. Vergleichen Sie den Fingerprint mit dem Server, z. B. per `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.")
                fingerprintBox(fingerprint)
                buttons(key: key, trustLabel: String(localized: "Vertrauen und verbinden"), role: nil)
            case .hostKeyChanged(let key, let fingerprint):
                Label("Host-Key hat sich geändert", systemImage: "exclamationmark.shield")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                Text("\(connection.config.name) meldet sich mit einem anderen Schlüssel als bisher. Das kann eine Neuinstallation des Servers sein, aber auch ein Angriff. Vertrauen Sie dem neuen Schlüssel nur, wenn Sie den Grund kennen.")
                fingerprintBox(fingerprint)
                buttons(key: key, trustLabel: String(localized: "Neuen Schlüssel vertrauen"), role: .destructive)
            default:
                Text("Keine Entscheidung nötig.")
                Button("Schließen") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func fingerprintBox(_ fingerprint: String) -> some View {
        Text(fingerprint)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func buttons(key: String, trustLabel: String, role: ButtonRole?) -> some View {
        HStack {
            Spacer()
            Button("Später") {
                onLater()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(trustLabel, role: role) {
                store.trustHostKey(key, for: connection.id)
                dismiss()
            }
        }
    }
}
