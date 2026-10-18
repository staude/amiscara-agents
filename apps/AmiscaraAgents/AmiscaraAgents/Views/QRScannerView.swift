#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// Scans an "add host" QR code with the camera. A code that is not valid
/// shows why and scanning goes on; a valid one is handed over and closes
/// the scanner.
struct QRScannerView: View {
    let onLink: (AddHostLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    /// Camera access as far as known; nil while the system asks.
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if cameraAllowed == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cameraAllowed == true && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onText: handle, onError: { problem = $0 })
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
            .task { cameraAllowed = await requestCameraAccess() }
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

/// Asks for the camera first: `DataScannerViewController.isAvailable` is only
/// meaningful once the user has decided, and the scanner itself does not ask.
private func requestCameraAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
    default: false
    }
}

/// VisionKit's scanner, QR codes only.
private struct Scanner: UIViewControllerRepresentable {
    let onText: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return ScannerHost(scanner: scanner, onError: onError)
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {
        context.coordinator.onText = onText
        host.onError = onError
    }

    static func dismantleUIViewController(_ host: ScannerHost, coordinator: Coordinator) {
        host.scanner.stopScanning()
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

/// Holds the scanner as a child and starts it once it is on screen. Started
/// any earlier, from `updateUIViewController`, the camera stays black.
private final class ScannerHost: UIViewController {
    let scanner: DataScannerViewController
    var onError: (String) -> Void

    init(scanner: DataScannerViewController, onError: @escaping (String) -> Void) {
        self.scanner = scanner
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            onError(String(localized: "Die Kamera ließ sich nicht starten: \(error.localizedDescription)"))
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }
}
#endif
