import SwiftUI

/// Secrets for a host (#291): environment variables such as tokens that go
/// to `~/.amiscara-agents/env/<NAME>` on the host over SFTP instead of
/// through a pane. The values stay in this device's Keychain so they can be
/// sent again; they are never shown, logged or read back from the host.
struct SecretsView: View {
    let connection: HostConnection
    @Environment(\.dismiss) private var dismiss
    /// Names with a value on this device.
    @State private var localNames: [String] = []
    /// Names on the host; `nil` while loading or when the host could not
    /// be read.
    @State private var hostNames: Set<String>?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var busy = false
    @State private var newName = ""
    @State private var newValue = ""

    private var hostID: UUID { connection.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let names = allNames
                    if names.isEmpty && hostNames != nil {
                        Text("Noch keine Geheimnisse.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(names, id: \.self) { name in
                        row(name)
                    }
                    if hostNames == nil && loadError == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    if let loadError {
                        Text(loadError)
                    }
                }
                Section {
                    TextField("Name, z. B. NB_TOKEN", text: $newName)
                        .technicalInput()
                        .font(.body.monospaced())
                    SecureField("Wert", text: $newValue)
                        .technicalInput()
                        .onSubmit { if canSendNew { sendNew() } }
                    Button("An Host senden", systemImage: "arrow.up.circle", action: sendNew)
                        .disabled(!canSendNew)
                } header: {
                    Text("Neues Geheimnis")
                } footer: {
                    if !trimmedName.isEmpty && !isValidEnvName(name: trimmedName) {
                        Text("Erlaubt sind Großbuchstaben A–Z, Ziffern und _, am Anfang keine Ziffer.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Der Wert landet auf dem Host in ~/.amiscara-agents/env, nur für Sie lesbar, und bleibt auf diesem Gerät im Schlüsselbund. Neue Shells in herdr-Panes setzen die Variable, laufende Agenten lesen sie mit „amiscara-env NAME“.")
                    }
                }
                if let actionError {
                    Section {
                        Text(actionError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Geheimnisse auf \(connection.config.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task { await reload() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private var allNames: [String] {
        Set(localNames).union(hostNames ?? []).sorted()
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private var canSendNew: Bool {
        !busy && isValidEnvName(name: trimmedName) && !newValue.isEmpty
    }

    @ViewBuilder
    private func row(_ name: String) -> some View {
        let onDevice = localNames.contains(name)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.monospaced())
                HStack(spacing: 6) {
                    if onDevice {
                        Text(verbatim: "••••••")
                    }
                    if let status = status(name, onDevice: onDevice) {
                        Text(status)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if onDevice {
                Button("An Host senden", systemImage: "arrow.up.circle") { resend(name) }
                    .labelStyle(.iconOnly)
                    .help(String(localized: "An Host senden"))
            }
            Button("Entfernen", systemImage: "trash", role: .destructive) { remove(name) }
                .labelStyle(.iconOnly)
                .help(String(localized: "Entfernen"))
        }
        .buttonStyle(.borderless)
        .disabled(busy)
    }

    private func status(_ name: String, onDevice: Bool) -> String? {
        guard let hostNames else { return nil }
        switch (onDevice, hostNames.contains(name)) {
        case (true, true): return String(localized: "auf dem Host")
        case (true, false): return String(localized: "nicht gesendet")
        case (false, _): return String(localized: "nur auf dem Host")
        }
    }

    private func reload() async {
        localNames = SecretStore.names(for: hostID)
        do {
            hostNames = Set(try await connection.secretNames())
            loadError = nil
        } catch {
            hostNames = nil
            loadError = String(localized: "Geheimnisse auf dem Host nicht lesbar: \(Self.reason(error))")
        }
    }

    private func sendNew() {
        let name = trimmedName
        let value = newValue
        run(failed: { String(localized: "Senden fehlgeschlagen: \($0)") }) {
            try await connection.sendSecret(name: name, value: value)
            try SecretStore.save(value: value, name: name, host: hostID)
            newName = ""
            newValue = ""
        }
    }

    private func resend(_ name: String) {
        run(failed: { String(localized: "Senden fehlgeschlagen: \($0)") }) {
            guard let value = try SecretStore.load(name: name, host: hostID) else { return }
            try await connection.sendSecret(name: name, value: value)
        }
    }

    /// On the host first, so a value whose file could not be deleted stays
    /// here to try again.
    private func remove(_ name: String) {
        run(failed: { String(localized: "Entfernen fehlgeschlagen: \($0)") }) {
            try await connection.removeSecret(name: name)
            SecretStore.delete(name: name, host: hostID)
        }
    }

    /// The core's own message for file errors, which `inputErrorMessage`
    /// words for uploads and reading.
    private static func reason(_ error: Error) -> String {
        switch error {
        case FfiError.Upload(let message), FfiError.Files(let message):
            message
        default:
            inputErrorMessage(error)
        }
    }

    private func run(
        failed: @escaping (String) -> String,
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        busy = true
        actionError = nil
        Task {
            do {
                try await action()
            } catch {
                actionError = failed(Self.reason(error))
            }
            await reload()
            busy = false
        }
    }
}
