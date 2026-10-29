// Checks the NetBird host rules (#305) without the UI. Built by
// scripts/netbird-test.sh.
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

check(!NetBird.isNetBirdAddress("100.63.255.255"), "100.63.x is below the range")
check(NetBird.isNetBirdAddress("100.64.0.0"), "range starts at 100.64.0.0")
check(NetBird.isNetBirdAddress("100.127.255.255"), "range ends at 100.127.255.255")
check(!NetBird.isNetBirdAddress("100.128.0.1"), "100.128.x is above the range")
check(!NetBird.isNetBirdAddress("10.64.0.1"), "other first octet")
check(!NetBird.isNetBirdAddress("100.64.0"), "too few octets")
check(!NetBird.isNetBirdAddress("100.64.0.300"), "octet out of range")
check(!NetBird.isNetBirdAddress("work.staude.internal"), "a name is no address")

check(NetBird.looksLikeNetBirdHost("100.100.1.2"), "address in range")
check(NetBird.looksLikeNetBirdHost("Work.NetBird.Cloud"), "default domain, any case")
check(NetBird.looksLikeNetBirdHost("work.netbird.selfhosted."), "trailing dot")
check(NetBird.looksLikeNetBirdHost("  work.netbird.cloud "), "surrounding spaces")
check(!NetBird.looksLikeNetBirdHost(""), "empty host")
check(!NetBird.looksLikeNetBirdHost("work.staude.internal"), "own domain is learned, not guessed")
check(!NetBird.looksLikeNetBirdHost("192.168.1.5"), "home network address")

check(!NetBird.isBehind(switch: false, host: "100.100.1.2", learned: true), "switch off beats address and learning")
check(NetBird.isBehind(switch: true, host: "192.168.1.5", learned: false), "switch on beats a plain host")
check(NetBird.isBehind(switch: nil, host: "work.netbird.cloud", learned: nil), "automatic: default domain")
check(NetBird.isBehind(switch: nil, host: "work.staude.internal", learned: true), "automatic: learned")
check(!NetBird.isBehind(switch: nil, host: "work.staude.internal", learned: false), "automatic: learned not NetBird")
check(!NetBird.isBehind(switch: nil, host: "work.staude.internal", learned: nil), "automatic: nothing known")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("netbird: ok")
