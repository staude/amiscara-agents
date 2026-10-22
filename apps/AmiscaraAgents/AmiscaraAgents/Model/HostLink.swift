import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// "Add host" links and their QR codes. The format and its strict checks live
// in Rust (crates/herdr-ffi/src/add_host.rs, with unit tests); this file only
// connects them to the app.

/// Why a link was refused, for the user, or a generic message for other
/// errors.
func hostLinkErrorMessage(_ error: Error) -> String {
    switch error {
    case let error as AddHostLinkError: error.message
    case FfiError.Key(let message): String(localized: "Ungültiger Schlüssel: \(message)")
    default: error.localizedDescription
    }
}

extension AddHostLinkError {
    /// The reason in the user's language; the core only names it.
    var message: String {
        switch self {
        case .TooLong: String(localized: "Der Code ist zu lang.")
        case .NotALink: String(localized: "Das ist kein Amiscara-Agents-Code zum Hinzufügen eines Hosts.")
        case .Damaged: String(localized: "Der Code ist beschädigt.")
        case .UnknownField(let field): String(localized: "Der Code enthält ein unbekanntes Feld „\(field)“.")
        case .DuplicateField(let field): String(localized: "Das Feld „\(field)“ steht mehrfach im Code.")
        case .MissingVersion: String(localized: "Dem Code fehlt die Versionsangabe.")
        case .BadVersion: String(localized: "Die Versionsangabe im Code ist ungültig.")
        case .NewerVersion: String(localized: "Der Code stammt von einer neueren App-Version. Bitte aktualisieren Sie Amiscara Agents.")
        case .MissingHost: String(localized: "Im Code fehlt der Host.")
        case .BadHost(let host): String(localized: "Der Host „\(host)“ im Code ist ungültig.")
        case .BadPort: String(localized: "Der Port im Code ist ungültig.")
        case .MissingUser: String(localized: "Im Code fehlt der Benutzer.")
        case .BadUser(let user): String(localized: "Der Benutzer „\(user)“ im Code ist ungültig.")
        case .BadSocket: String(localized: "Der Socket-Pfad im Code ist ungültig. Erwartet wird ein absoluter Pfad.")
        case .MissingKey: String(localized: "Im Code fehlt der Host-Key.")
        case .KeyNotOneLine: String(localized: "Der Host-Key im Code muss genau eine Zeile sein.")
        case .KeyTooLong: String(localized: "Der Host-Key im Code ist zu lang.")
        case .BadKey: String(localized: "Der Host-Key im Code ist kein gültiger OpenSSH-Schlüssel.")
        case .BadName: String(localized: "Der Name im Code ist ungültig.")
        }
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
