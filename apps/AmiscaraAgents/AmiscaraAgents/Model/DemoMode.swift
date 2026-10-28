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
/// - `-demoView <name>`: on top, `switcher`, `addHost`, `conversation`,
///   `files` or (Mac) `settings`; instead of a space `overview` or
///   `dashboard` (the demo host's); `offline` takes the host offline
///   after 3 s, so the pane shows its last screen dimmed (#290).
/// - `-demoSearch <text>`: the pane search, open with this text.
/// - `-demoWindow <width>x<height>`: the Mac window's content size.
/// - `-demoHistory <text>`: a prompt in the history of the pane (#229).
/// - `-demoHome <path>`: the home the local host's files and Claude
///   conversations are read from. The simulators set their own `HOME`
///   and ignore `SIMCTL_CHILD_HOME`, so the app sets it at launch (#290).
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
    static let history = UserDefaults.standard.string(forKey: "demoHistory")
    #else
    static let socket: String? = nil
    static let space: String? = nil
    static let pane: String? = nil
    static let view: String? = nil
    static let search: String? = nil
    static let window: String? = nil
    static let widgets = false
    static let history: String? = nil
    #endif

    static var isOn: Bool { socket != nil }

    /// Points `HOME` at `-demoHome` before the core reads it (#290).
    static func applyHome() {
        #if DEBUG
        guard isOn, let home = UserDefaults.standard.string(forKey: "demoHome"), !home.isEmpty else { return }
        setenv("HOME", home, 1)
        #endif
    }

    /// `-demoWindow` as a size.
    static var windowSize: CGSize? {
        let parts = window?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// The demo host: the session's socket, without notifications.
    /// A fixed id, so links into the demo (UI tests) can name the host.
    static let hostID = UUID(uuidString: "00000000-0000-0000-0000-00000000DE30")!

    static func host(socket: String) -> HostConfig {
        var config = HostConfig(id: hostID, name: "Mac Studio", kind: .local)
        config.socketPath = socket
        config.notificationsOn = false
        return config
    }
}
