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

#if os(iOS) || os(macOS)
/// Turns Spotlight indexing of spaces and agents on and off (#308); on the
/// Mac in the settings window, on iOS in the "Erscheinungsbild" menu.
struct SpotlightToggle: View {
    @AppStorage(SpotlightIndex.enabledKey) private var enabled = true

    var body: some View {
        Toggle("Spaces und Agents in Spotlight", isOn: $enabled)
            .onChange(of: enabled) { SpotlightIndex.shared.settingChanged() }
    }
}
#endif

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
            Section {
                AppLockSettings()
            } header: {
                Text("App-Sperre")
            } footer: {
                Text("Fragt nach Touch ID oder dem Passwort, wenn Sie zur App zurückkehren.")
            }
            Section {
                SpotlightToggle()
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Namen, Branch und Status von Spaces und Agents gehen in die Systemsuche.")
            }
            UpdateSettings()
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .appLock()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Updates as in Kastellan: automatically every 24 hours, or now.
private struct UpdateSettings: View {
    @State private var updater = UpdaterController.shared

    var body: some View {
        Section {
            Toggle("Automatisch nach Updates suchen", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isAvailable)
            LabeledContent {
                Button("Jetzt suchen") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
            } label: {
                Text("Version \(Self.version)")
                if let last = updater.lastUpdateCheckDate {
                    Text("Zuletzt gesucht \(last.formatted(.relative(presentation: .named)))")
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updater.isAvailable
                 ? "Amiscara Agents sucht beim Start und danach alle 24 Stunden nach einer neuen Version. Updates laden im Hintergrund und werden beim nächsten Beenden installiert."
                 : "Dieser Build aktualisiert sich nicht selbst (Entwickler-Build). Neue Versionen gibt es unter github.com/staude/amiscara-agents/releases.")
                .foregroundStyle(.secondary)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
#endif
