#if os(tvOS)
import SwiftUI

/// Pairing on the TV (#127): shows the QR code for the iPhone and waits for
/// the hosts it leaves in iCloud.
struct TVPairingView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var key: SshKey?
    @State private var error: String?
    @State private var added = 0

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            Group {
                if let key, let image = QRCode.image(for: link(key).url.absoluteString, scale: 12) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(width: 560, height: 560)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                Text("Mit dem iPhone koppeln").font(.title2.bold())
                Text("1. Den Code mit der Kamera des iPhones scannen. Amiscara Agents öffnet sich dort.")
                Text("2. Auf dem iPhone die Hosts wählen und „Koppeln“ tippen. Das iPhone trägt den Schlüssel dieses Apple TV auf den Hosts ein.")
                Text("3. Die Hosts erscheinen hier nach wenigen Sekunden. iPhone und Apple TV brauchen dieselbe Apple-ID.")
                if let key {
                    LabeledContent("Fingerabdruck", value: key.fingerprint)
                        .font(.callout.monospaced())
                }
                if added > 0 {
                    Label("\(added) Host(s) hinzugefügt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Fertig") { dismiss() }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(80)
        .task {
            do {
                key = try TVKey.load()
            } catch {
                self.error = String(localized: "Schlüssel nicht verfügbar: \(error.localizedDescription)")
                return
            }
            // Until closed: pick up hosts as the iPhone leaves them.
            while !Task.isCancelled {
                added += await store.adoptPairedHosts()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func link(_ key: SshKey) -> TVPairing.Link {
        TVPairing.Link(tvID: TVKey.tvID, name: UIDevice.current.name, publicKey: key.publicOpenssh)
    }
}
#endif
