import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Light or dark look of the app: as the system (default) or fixed.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Wie das System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppearancePicker: View {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    var body: some View {
        Picker("Erscheinungsbild", selection: $appearance) {
            ForEach(Appearance.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}

extension View {
    /// Applies the chosen appearance. On the Mac through `NSApp`, so the
    /// menu bar item follows and "Wie das System" switches back at once
    /// (`preferredColorScheme(nil)` keeps the last fixed look there).
    func appAppearance(_ appearance: Appearance) -> some View {
        #if os(macOS)
        onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        #else
        preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(macOS)
/// The app's settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        Form {
            AppearancePicker()
                .pickerStyle(.radioGroup)
            Section("Terminal") {
                TerminalSettings()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
