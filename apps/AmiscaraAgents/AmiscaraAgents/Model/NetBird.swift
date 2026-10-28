import Foundation

/// Rules for recognising hosts behind NetBird (#305). Pure, so the test in
/// `Tests/NetBird` builds it alone.
enum NetBird {
    /// Bundle id of NetBird's menu bar app on the Mac.
    static let macBundleID = "io.netbird.client"
    /// URL scheme of the NetBird app on iPhone and iPad.
    static let iosURL = "netbird://"

    /// Whether an IPv4 address lies in 100.64.0.0/10, where NetBird (and
    /// other overlay VPNs) put their peers.
    static func isNetBirdAddress(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = UInt8(parts[0]), let second = UInt8(parts[1]),
              parts[2...].allSatisfy({ UInt8($0) != nil }) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// Whether the host entry itself says NetBird: an address in the NetBird
    /// range or one of its default domains. Own domains are learned instead.
    static func looksLikeNetBirdHost(_ host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }
        return isNetBirdAddress(name) || name.hasSuffix(".netbird.cloud") || name.hasSuffix(".netbird.selfhosted")
    }
}
