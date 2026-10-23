import CoreGraphics
import Foundation

/// Screenshot demo (#199): launch arguments that point the app at the
/// seeded demo session of `scripts/screenshots` and open a view, so the
/// screenshots show the same screens on every run. Debug builds only;
/// in release builds the mode is always off.
///
/// - `-demoSocket <path>`: the only host, the demo session's socket,
///   kept in memory. Nothing is saved, published to widgets or iCloud.
///   Works in the simulators too, which reach the Mac's sockets.
/// - `-demoSpace <label>`: the space to open, by its herdr label.
/// - `-demoPane <pane id>`: the pane to select in it.
/// - `-demoView <name>`: on top, `switcher`, `addHost`, `conversation`
///   or (Mac) `settings`.
/// - `-demoSearch <text>`: the pane search, open with this text.
/// - `-demoWindow <width>x<height>`: the Mac window's content size.
/// - `-demoWidgets YES`: publish the demo board to the widgets after all,
///   for screenshots of widgets placed by hand (#215).
enum DemoMode {
    #if DEBUG
    static let socket = UserDefaults.standard.string(forKey: "demoSocket")
    static let space = UserDefaults.standard.string(forKey: "demoSpace")
    static let pane = UserDefaults.standard.string(forKey: "demoPane")
    static let view = UserDefaults.standard.string(forKey: "demoView")
    static let search = UserDefaults.standard.string(forKey: "demoSearch")
    static let window = UserDefaults.standard.string(forKey: "demoWindow")
    static let widgets = UserDefaults.standard.bool(forKey: "demoWidgets")
    #else
    static let socket: String? = nil
    static let space: String? = nil
    static let pane: String? = nil
    static let view: String? = nil
    static let search: String? = nil
    static let window: String? = nil
    static let widgets = false
    #endif

    static var isOn: Bool { socket != nil }

    /// `-demoWindow` as a size.
    static var windowSize: CGSize? {
        let parts = window?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// The demo host: the session's socket, without notifications.
    static func host(socket: String) -> HostConfig {
        var config = HostConfig(name: "Mac Studio", kind: .local)
        config.socketPath = socket
        config.notificationsOn = false
        return config
    }
}
