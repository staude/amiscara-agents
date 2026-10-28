import Foundation

/// When a host was last seen connected, so the overview can tell how old
/// the agents it still shows are (#274): every update while live, and the
/// one that ends the connection, since until then the last update was
/// still current, however quiet the host was. Not when a reconnect was
/// asked for while the link still looked live, e.g. after the device
/// slept: its end says nothing about when the host was last reachable.
struct LiveClock: Equatable {
    private(set) var liveAt: Date?
    private var suspect = false

    /// A reconnect is asked for; `live` is whether the link looks live.
    mutating func reconnecting(live: Bool) {
        if live { suspect = true }
    }

    /// An update arrived; `wasLive` and `isLive` are the states before and
    /// after it.
    mutating func update(wasLive: Bool, isLive: Bool, now: Date = .now) {
        if isLive {
            liveAt = now
            suspect = false
        } else if wasLive && !suspect {
            liveAt = now
        }
    }
}
