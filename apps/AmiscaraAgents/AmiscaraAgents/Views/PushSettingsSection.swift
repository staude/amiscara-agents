#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// APNs key and registered devices for pushes from this Mac (#94).
struct PushSettingsSection: View {
    let sender: PushSender
    @State private var keyID = ""
    @State private var importing = false
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        Section {
            if sender.configured, let keyID = sender.keyID {
                LabeledContent("APNs-Schlüssel", value: keyID)
                Button("Schlüssel entfernen", role: .destructive) { sender.removeKey() }
            } else {
                TextField("Key-ID", text: $keyID, prompt: Text("ABC123DEFG"))
                    .technicalInput()
                Button("Schlüssel (.p8) wählen …") { importing = true }
                    .disabled(keyID.trimmingCharacters(in: .whitespaces).count != 10)
            }
            let devices = sender.devices
            if devices.isEmpty {
                Text("Noch kein iPhone oder iPad angemeldet.").foregroundStyle(.secondary)
            } else {
                ForEach(devices, id: \.token) { device in
                    LabeledContent(device.deviceName) {
                        HStack {
                            Text(device.sandbox ? "Entwicklung" : "Release").foregroundStyle(.secondary)
                            Button("Entfernen", systemImage: "minus.circle") { sender.remove(device) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(String(localized: "Keine Pushes mehr an dieses Gerät, bis es sich wieder anmeldet"))
                        }
                    }
                }
                Button(testing ? "Wird gesendet …" : "Test-Push senden") {
                    testing = true
                    Task {
                        await sender.sendTest()
                        testing = false
                    }
                }
                .disabled(!sender.configured || testing)
            }
            if let message = error ?? sender.lastError {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Push an iPhone und iPad")
        } footer: {
            Text("Dieser Mac schickt „wartet“ und „fertig“ als Push an iPhones und iPads, auf denen dieser Host mit Dateizugriff eingerichtet ist; die Apple Watch zeigt sie mit Antwort-Knöpfen. Dafür einmal im Developer-Konto unter Keys einen Schlüssel für „Apple Push Notifications service“ anlegen. Er bleibt im Schlüsselbund dieses Macs.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let pem = try String(contentsOf: url, encoding: .utf8)
                try sender.setKey(pem: pem, keyID: keyID)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
