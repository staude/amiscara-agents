import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// "Add host" links and their QR codes. The format and its strict checks live
// in Rust (crates/herdr-ffi/src/add_host.rs, with unit tests); this file only
// connects them to the app.

/// The German message for a refused link, or a generic one for other errors.
func hostLinkErrorMessage(_ error: Error) -> String {
    switch error {
    case FfiError.InvalidLink(let message): message
    case FfiError.Key(let message): String(localized: "Ungültiger Schlüssel: \(message)")
    default: error.localizedDescription
    }
}

extension HostStore {
    /// Why a host key from a scanned or opened code must not be pinned for
    /// `host`:`port`, or nil. A code never replaces a host key the user
    /// already trusts, neither on the host being edited nor on another host
    /// at the same address: that is exactly what a forged code would try.
    /// Checked on import and again on save.
    ///
    /// `original` is the host as stored before editing, so a second scan in
    /// the same editor may still replace the key of the first scan.
    func hostKeyConflict(host: String, port: Int, key: String, editing original: HostConfig) -> String? {
        if let pinned = original.pinnedHostKey, !Self.sameKey(pinned, key) {
            return String(localized: "Der Code enthält einen anderen Host-Key als den, dem dieser Host vertraut. Er wurde nicht übernommen. Wenn der Server neu aufgesetzt wurde, entfernen Sie den Host und fügen ihn neu hinzu.")
        }
        let address = Self.normalizedHost(host)
        let others = connections.map(\.config).filter { other in
            other.id != original.id && other.kind == .ssh
                && Self.normalizedHost(other.host) == address
                && other.port == port
        }
        for other in others {
            if let pinned = other.pinnedHostKey, !Self.sameKey(pinned, key) {
                return String(localized: "„\(other.name)“ unter derselben Adresse vertraut einem anderen Host-Key. Der Code wurde nicht übernommen. Prüfen Sie den Host-Key auf dem Server.")
            }
        }
        return nil
    }

    /// "Mac.Example.Internal." and "mac.example.internal" are one host.
    static func normalizedHost(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Same algorithm and key data; the comment does not matter.
    static func sameKey(_ a: String, _ b: String) -> Bool {
        let fields = { (line: String) in line.split(separator: " ", omittingEmptySubsequences: true).prefix(2) }
        return fields(a) == fields(b)
    }
}

enum QRCode {
    /// A QR code for `text`, one pixel per module scaled up `scale` times,
    /// black on white. Level M survives a bit of glare on a screen.
    static func image(for text: String, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
