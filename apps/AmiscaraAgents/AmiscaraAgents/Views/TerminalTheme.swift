import SwiftUI

/// Light or dark terminal: as the app (default) or fixed.
enum TerminalAppearance: String, CaseIterable, Identifiable {
    case app, light, dark

    static let storageKey = "terminalAppearance"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .app: "Wie die App"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
}

/// Background, text and the 16 base colors of the terminal. The desktop
/// app has the same schemes (`apps/desktop/src/lib/term.ts`).
enum TerminalScheme: String, CaseIterable, Identifiable {
    case standard, solarized, apple

    static let storageKey = "terminalScheme"
    /// Lightens or darkens text colors that are too faint on their background.
    static let contrastKey = "terminalMinContrast"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .standard: "Standard"
        case .solarized: "Solarized"
        case .apple: "Terminal (macOS)"
        }
    }
}

struct RGB: Equatable {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        self.init(Double(hex >> 16 & 0xff) / 255, Double(hex >> 8 & 0xff) / 255, Double(hex & 0xff) / 255)
    }

    static let black = RGB(0, 0, 0)
    static let white = RGB(1, 1, 1)

    var color: Color { Color(red: r, green: g, blue: b) }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// Relative luminance after WCAG 2.
    var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(to other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The resolved colors a pane is drawn with.
struct TerminalTheme: Equatable {
    var background: RGB
    var foreground: RGB
    var base: [RGB]
    var isDark: Bool
    var minContrast: Bool

    /// Contrast ratio text gets at least with `minContrast` (WCAG AA); colors
    /// move only as far as needed, so they stay recognizable.
    static let contrastTarget = 4.5

    init(scheme: TerminalScheme, dark: Bool, minContrast: Bool) {
        isDark = dark
        self.minContrast = minContrast
        switch (scheme, dark) {
        case (.standard, true):
            background = RGB(0.11, 0.11, 0.12)
            foreground = RGB(0.88, 0.88, 0.88)
            base = Self.standardBase
        case (.standard, false):
            background = .white
            foreground = RGB(hex: 0x1b1f20)
            base = Self.standardBase
        case (.solarized, true):
            background = RGB(hex: 0x002b36)
            foreground = RGB(hex: 0x839496)
            base = Self.solarizedBase
        case (.solarized, false):
            background = RGB(hex: 0xfdf6e3)
            foreground = RGB(hex: 0x657b83)
            base = Self.solarizedBase
        case (.apple, true):
            background = RGB(hex: 0x1e1e1e)
            foreground = RGB(hex: 0xf2f2f2)
            base = Self.appleBase
        case (.apple, false):
            background = .white
            foreground = .black
            base = Self.appleBase
        }
    }

    /// `foreground` on `background`, lightened or darkened until it is
    /// readable when `minContrast` is on.
    func readable(_ foreground: RGB, on background: RGB) -> RGB {
        guard minContrast, foreground.contrast(to: background) < Self.contrastTarget else { return foreground }
        let target = RGB.white.contrast(to: background) >= RGB.black.contrast(to: background) ? RGB.white : .black
        // The least change that reaches the target.
        var (low, high) = (0.0, 1.0)
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if foreground.mixed(with: target, mid).contrast(to: background) < Self.contrastTarget {
                low = mid
            } else {
                high = mid
            }
        }
        return foreground.mixed(with: target, high)
    }

    private static let standardBase = [
        RGB(0.00, 0.00, 0.00), RGB(0.80, 0.24, 0.24), RGB(0.36, 0.72, 0.36), RGB(0.80, 0.68, 0.24),
        RGB(0.26, 0.46, 0.84), RGB(0.69, 0.36, 0.78), RGB(0.24, 0.68, 0.74), RGB(0.80, 0.80, 0.80),
        RGB(0.46, 0.46, 0.46), RGB(0.96, 0.40, 0.40), RGB(0.52, 0.88, 0.52), RGB(0.96, 0.86, 0.40),
        RGB(0.46, 0.64, 0.98), RGB(0.86, 0.52, 0.96), RGB(0.42, 0.86, 0.92), RGB(1.00, 1.00, 1.00),
    ]

    private static let solarizedBase = [
        0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
        0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
    ].map { RGB(hex: UInt32($0)) }

    private static let appleBase = [
        0x000000, 0x990000, 0x00a600, 0x999900, 0x0000b2, 0xb200b2, 0x00a6b2, 0xbfbfbf,
        0x666666, 0xe50000, 0x00d900, 0xe5e500, 0x0000ff, 0xe500e5, 0x00e5e5, 0xe5e5e5,
    ].map { RGB(hex: UInt32($0)) }
}

/// Hands its content the terminal theme from the settings and the app's
/// look, and draws the content on the terminal background.
struct TerminalThemeReader<Content: View>: View {
    @ViewBuilder var content: (TerminalTheme) -> Content
    @AppStorage(TerminalAppearance.storageKey) private var appearance: TerminalAppearance = .app
    @AppStorage(TerminalScheme.storageKey) private var scheme: TerminalScheme = .standard
    @AppStorage(TerminalScheme.contrastKey) private var minContrast = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = switch appearance {
        case .app: colorScheme == .dark
        case .light: false
        case .dark: true
        }
        let theme = TerminalTheme(scheme: scheme, dark: dark, minContrast: minContrast)
        content(theme)
            .background(theme.background.color, ignoresSafeAreaEdges: [])
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

#if !os(tvOS)
/// Terminal settings: light or dark, color scheme, minimum contrast.
struct TerminalSettings: View {
    @AppStorage(TerminalAppearance.storageKey) private var appearance: TerminalAppearance = .app
    @AppStorage(TerminalScheme.storageKey) private var scheme: TerminalScheme = .standard
    @AppStorage(TerminalScheme.contrastKey) private var minContrast = true
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false

    var body: some View {
        Picker("Terminal", selection: $appearance) {
            ForEach(TerminalAppearance.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        Picker("Farbschema", selection: $scheme) {
            ForEach(TerminalScheme.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        Toggle("Mindestkontrast", isOn: $minContrast)
            .help(String(localized: "Hellt zu schwache Schriftfarben auf oder dunkelt sie ab"))
        Toggle(isOn: $wrapLines) {
            Text("Zeilen umbrechen (experimentell)")
            Text("Nicht von herdr vorgesehen: herdr liefert die Zeilen in der Breite des Panes auf dem Host. Was das Terminal umgebrochen hat, setzt die App wieder zusammen und bricht es an der Fensterbreite um. Vollbild-Agenten wie Claude Code brechen selbst um, ihre Zeilen und Rahmen werden nur gekürzt oder ein zweites Mal umgebrochen.")
        }
        .help(String(localized: "Lange Zeilen an der Fensterbreite umbrechen statt seitlich zu scrollen"))
    }
}
#endif
