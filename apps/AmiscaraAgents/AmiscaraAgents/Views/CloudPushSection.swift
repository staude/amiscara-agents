#if os(macOS)
import CloudKit
import SwiftUI

/// Status of pushes through iCloud from this Mac (#119).
struct CloudPushSection: View {
    let sender: CloudPushSender
    @Bindable private var commands = CloudCommandReceiver.shared

    var body: some View {
        Section {
            LabeledContent("iCloud", value: accountText)
            if sender.hostKey == nil {
                Text("Ohne SSH-Host-Key dieses Macs erkennen die Geräte den Host nicht. In den Systemeinstellungen unter Allgemein > Teilen die entfernte Anmeldung einschalten.")
                    .foregroundStyle(.orange)
            }
            Toggle("Auch für SSH-Hosts senden", isOn: Binding(
                get: { sender.includeSSHHosts },
                set: { sender.includeSSHHosts = $0 }
            ))
            Button("Test-Push senden") { sender.sendTest() }
                .disabled(sender.accountStatus != .available || sender.hostKey == nil)
            if let error = sender.lastError {
                Text(error).foregroundStyle(.red)
            }
            Toggle("Befehle von der Apple Watch annehmen", isOn: $commands.enabled)
            if commands.enabled, let last = commands.lastCommand {
                LabeledContent("Zuletzt", value: "\(last.text), \(last.date.formatted(date: .omitted, time: .shortened))")
            }
            if commands.enabled, let error = commands.lastError {
                Text(error).foregroundStyle(.orange)
            }
        } header: {
            Text("Push über iCloud")
        } footer: {
            Text("Dieser Mac legt „wartet“ und „fertig“ in Ihrer privaten iCloud ab; iPhone und iPad mit derselben Apple-ID bekommen sie als Push, auch die Apple Watch, mit Antwort-Knöpfen. Die Geräte müssen diesen Mac als Host eingerichtet haben. Mit „Auch für SSH-Hosts senden“ gilt das auch für die Hosts, mit denen dieser Mac verbunden ist, etwa einen Linux-Server ohne eigene Mac-App; dieselbe Meldung von einem zweiten Mac kommt nicht doppelt. „Befehle von der Apple Watch annehmen“ (aus, wenn nicht eingeschaltet): Ist das iPhone nicht in Reichweite, legt die Watch Antworten (1, 2, 3, Enter, Esc) und Prompts in iCloud ab, und dieser Mac schickt sie an die Hosts, für die er sendet. Jedes Gerät mit derselben Apple-ID kann dann Eingaben schicken; „Eingaben erlauben“ des Hosts gilt weiter, Befehle verfallen nach 60 Sekunden.")
        }
        .task { await sender.refreshAccount() }
    }

    private var accountText: String {
        switch sender.accountStatus {
        case .available: String(localized: "angemeldet")
        case .noAccount: String(localized: "nicht angemeldet")
        case .restricted: String(localized: "eingeschränkt")
        case .temporarilyUnavailable: String(localized: "vorübergehend nicht verfügbar")
        case .couldNotDetermine, .none: String(localized: "unbekannt")
        @unknown default: String(localized: "unbekannt")
        }
    }
}
#endif
