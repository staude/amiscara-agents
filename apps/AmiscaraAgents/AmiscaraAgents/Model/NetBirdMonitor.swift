import Foundation
import Network
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Whether NetBird is connected on this device (#305), read from the
/// network interfaces: the tunnel carries an IPv4 address in 100.64.0.0/10.
/// Every Apple device has several `utun` interfaces, so their mere presence
/// says nothing.
@MainActor @Observable
final class NetBirdMonitor {
    static let shared = NetBirdMonitor()

    /// nil until the first measurement, so nothing is flagged before that.
    private(set) var isUp: Bool?

    /// Called when the tunnel comes up after having been down or unknown.
    var onCameUp: (() -> Void)?

    #if !os(tvOS)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            let up = Self.tunnelIsUp()
            Task { @MainActor in self?.set(up) }
        }
        monitor.start(queue: DispatchQueue(label: "net.staude.amiscara.agents.netbird"))
    }

    private func set(_ up: Bool) {
        let wasUp = isUp == true
        isUp = up
        if up, !wasUp { onCameUp?() }
    }

    private nonisolated static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private nonisolated static func tunnelIsUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name).hasPrefix("utun"),
                  Int32(entry.ifa_flags) & IFF_UP != 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                                     nil, 0, NI_NUMERICHOST)
            if status == 0, NetBird.isNetBirdAddress(Self.string(buffer)) { return true }
        }
        return false
    }

    /// Whether the name resolves to an address in NetBird's range: true for
    /// one, false for only other addresses, nil when it does not resolve.
    nonisolated func resolvesToNetBird(_ host: String) async -> Bool? {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(result) }
            for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let address = pointer.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(address, pointer.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                                         nil, 0, NI_NUMERICHOST)
                if status == 0, NetBird.isNetBirdAddress(Self.string(buffer)) { return true }
            }
            return false
        }.value
    }

    /// Opens the NetBird app; false when it is not installed.
    func open() async -> Bool {
        #if os(iOS)
        guard let url = URL(string: NetBird.iosURL) else { return false }
        return await UIApplication.shared.open(url)
        #else
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NetBird.macBundleID) else { return false }
        do {
            try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
        #endif
    }
    #else
    private init() {}

    nonisolated func resolvesToNetBird(_ host: String) async -> Bool? { nil }

    func open() async -> Bool { false }
    #endif
}
