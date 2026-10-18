import SwiftUI

/// Keyboard shortcuts as menu commands: in the Mac menu bar, in the iPad
/// menu bar and in the overlay that holding ⌘ shows. The views publish what
/// they can do as focused scene values; a command without a provider is
/// disabled. All shortcuts carry ⌘, ⌥ or ⌃, so plain keys such as Esc or
/// the arrows keep working in text fields.
struct AppCommands: Commands {
    @FocusedValue(\.navigator) private var navigator
    @FocusedValue(\.tabNavigator) private var tabNavigator
    @FocusedValue(\.keySender) private var keySender
    @FocusedValue(\.paneSearch) private var paneSearch

    var body: some Commands {
        // In the Edit menu, where Find lives in every Mac app. SwiftUI adds
        // no Find items of its own here (that would take TextEditingCommands),
        // so ⌘F, ⌘G and ⇧⌘G belong to the pane search.
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Suchen …") { paneSearch?.open() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(paneSearch == nil)
            Button("Weitersuchen") { paneSearch?.step(1) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(paneSearch?.canStep != true)
            Button("Rückwärts suchen") { paneSearch?.step(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(paneSearch?.canStep != true)
        }
        CommandMenu("Gehe zu") {
            Button("Schnell wechseln …") { navigator?.openSwitcher() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(navigator == nil)
            Divider()
            ForEach(1..<10) { number in
                Button("Space \(number)") { navigator?.selectSpace(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled((navigator?.spaceCount ?? 0) < number)
            }
            Divider()
            Button("Vorheriger Tab") { tabNavigator?.step(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabNavigator == nil)
            Button("Nächster Tab") { tabNavigator?.step(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabNavigator == nil)
        }
        CommandMenu("Tasten") {
            key("Esc senden", "esc", ".", .command)
            key("Control-C senden", "ctrl+c", "c", .control)
            key("Enter senden", "enter", .return, [.command, .shift])
            Divider()
            key("Pfeil nach oben", "up", .upArrow, [.command, .option])
            key("Pfeil nach unten", "down", .downArrow, [.command, .option])
            key("Pfeil nach links", "left", .leftArrow, [.command, .option])
            key("Pfeil nach rechts", "right", .rightArrow, [.command, .option])
            Divider()
            ForEach(["1", "2", "3"], id: \.self) { option in
                Button("Option \(option) wählen") { keySender?.send([option]) }
                    .keyboardShortcut(KeyEquivalent(Character(option)), modifiers: [.command, .option])
                    .disabled(keySender?.isBlocked != true)
            }
        }
    }

    private func key(
        _ title: LocalizedStringKey,
        _ name: String,
        _ equivalent: KeyEquivalent,
        _ modifiers: EventModifiers
    ) -> some View {
        Button(title) { keySender?.send([name]) }
            .keyboardShortcut(equivalent, modifiers: modifiers)
            .disabled(keySender == nil)
    }
}

/// What the main window offers: the switcher and spaces by number.
struct Navigator {
    let openSwitcher: @MainActor () -> Void
    /// Number of spaces on the current host, for ⌘1 to ⌘9.
    let spaceCount: Int
    let selectSpace: @MainActor (Int) -> Void
}

/// Tabs of the open space.
struct TabNavigator {
    let step: @MainActor (Int) -> Void
}

/// The key bar of the open pane.
struct KeySender {
    let send: @MainActor ([String]) -> Void
    /// The agent waits at a dialog, so the options 1 to 3 make sense.
    let isBlocked: Bool
}

/// Search in the shown pane (the selected one in a split tab).
struct PaneSearchActions {
    let open: @MainActor () -> Void
    let step: @MainActor (Int) -> Void
    /// The bar is open and has matches.
    let canStep: Bool
}

extension FocusedValues {
    @Entry var navigator: Navigator?
    @Entry var tabNavigator: TabNavigator?
    @Entry var keySender: KeySender?
    @Entry var paneSearch: PaneSearchActions?
}
