#if os(iOS)
import SwiftUI
import VisionKit

/// Scans an "add host" QR code with the camera. A code that is not valid
/// shows why and scanning goes on; a valid one is handed over and closes
/// the scanner.
struct QRScannerView: View {
    let onLink: (AddHostLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onText: handle)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView {
                        Label("Kamera nicht verfügbar", systemImage: "camera")
                    } description: {
                        Text("Erlauben Sie Amiscara Agents in den Einstellungen den Zugriff auf die Kamera. Alternativ können Sie den Link vom Mac kopieren und im Host-Editor einfügen.")
                    }
                }
                Text(problem ?? String(localized: "Richten Sie die Kamera auf den QR-Code, den Amiscara Agents auf dem Mac zeigt."))
                    .font(.callout)
                    .foregroundStyle(problem == nil ? Color.primary : Color.red)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .navigationTitle("QR-Code scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        do {
            let link = try decodeAddHostLink(text: text)
            onLink(link)
            dismiss()
        } catch {
            problem = hostLinkErrorMessage(error)
        }
    }
}

/// VisionKit's scanner, QR codes only.
private struct Scanner: UIViewControllerRepresentable {
    let onText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onText = onText
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onText: (String) -> Void
        /// The scanner reports the same code again as it moves; one
        /// message per code is enough.
        private var last: String?

        init(onText: @escaping (String) -> Void) {
            self.onText = onText
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue, text != last else { continue }
                last = text
                onText(text)
            }
        }
    }
}
#endif
