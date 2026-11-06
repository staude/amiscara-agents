import SwiftUI

#if !os(tvOS)
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
    @FocusedValue(\.spaceCommands) private var spaceCommands
    @FocusedValue(\.paneCommands) private var paneCommands

    /// Behind the app lock (#232) no shortcut reaches a pane.
    private var locked: Bool { AppLock.shared.isCovered }

    var body: some Commands {
        // In the Edit menu, where Find lives in every Mac app. SwiftUI adds
        // no Find items of its own here (that would take TextEditingCommands),
        // so ⌘F, ⌘G and ⇧⌘G belong to the pane search.
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Suchen …") { if !locked { paneSearch?.open() } }
                .keyboardShortcut(Shortcuts.find)
                .disabled(paneSearch == nil)
            Button("Weitersuchen") { paneSearch?.step(1) }
                .keyboardShortcut(Shortcuts.findNext)
                .disabled(paneSearch?.canStep != true)
            Button("Rückwärts suchen") { paneSearch?.step(-1) }
                .keyboardShortcut(Shortcuts.findPrevious)
                .disabled(paneSearch?.canStep != true)
        }
        CommandMenu("Gehe zu") {
            Button("Schnell wechseln …") {
                guard !locked else { return }
                navigator?.openSwitcher(PaletteSources(
                    space: spaceCommands,
                    pane: paneCommands,
                    keySender: keySender,
                    paneSearch: paneSearch
                ))
            }
                .keyboardShortcut(Shortcuts.switcher)
                .disabled(navigator == nil)
            Button("Übergabe aus Zwischenablage …") { if !locked { navigator?.openHandoff() } }
                .keyboardShortcut(Shortcuts.handoff)
                .disabled(navigator == nil)
            Divider()
            ForEach(1..<10) { number in
                Button("Space \(number)") { navigator?.selectSpace(number) }
                    .keyboardShortcut(Shortcuts.space(number))
                    .disabled((navigator?.spaceCount ?? 0) < number)
            }
            Divider()
            Button("Vorheriger Tab") { tabNavigator?.step(-1) }
                .keyboardShortcut(Shortcuts.previousTab)
                .disabled(tabNavigator == nil)
            Button("Nächster Tab") { tabNavigator?.step(1) }
                .keyboardShortcut(Shortcuts.nextTab)
                .disabled(tabNavigator == nil)
        }
        CommandMenu("Tasten") {
            key("Esc senden", "esc", Shortcuts.escape)
            key("Control-C senden", "ctrl+c", Shortcuts.controlC)
            key("Enter senden", "enter", Shortcuts.enter)
            Divider()
            key("Pfeil nach oben", "up", Shortcuts.arrowUp)
            key("Pfeil nach unten", "down", Shortcuts.arrowDown)
            key("Pfeil nach links", "left", Shortcuts.arrowLeft)
            key("Pfeil nach rechts", "right", Shortcuts.arrowRight)
            Divider()
            ForEach(1...3, id: \.self) { number in
                let option = "\(number)"
                Button("Option \(option) wählen") { if !locked { keySender?.send([option]) } }
                    .keyboardShortcut(Shortcuts.option(number))
                    .disabled(keySender?.isBlocked != true)
            }
        }
    }

    private func key(_ title: LocalizedStringKey, _ name: String, _ shortcut: CommandShortcut) -> some View {
        Button(title) { if !locked { keySender?.send([name]) } }
            .keyboardShortcut(shortcut)
            .disabled(keySender == nil)
    }
}

extension CommandShortcut {
    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent = switch key {
        case "return": .return
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        default: KeyEquivalent(Character(key))
        }
        var flags: EventModifiers = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }
}

extension View {
    /// The shortcut from `Shortcuts`, the same the switcher shows.
    func keyboardShortcut(_ shortcut: CommandShortcut) -> some View {
        keyboardShortcut(shortcut.keyboardShortcut)
    }
}
#endif

/// What the main window offers: the switcher, spaces by number and the
/// handoff from the clipboard.
struct Navigator {
    /// With what the focused space and pane offer as commands (#346).
    let openSwitcher: @MainActor (PaletteSources) -> Void
    /// Number of spaces on the current host, for ⌘1 to ⌘9.
    let spaceCount: Int
    let selectSpace: @MainActor (Int) -> Void
    /// The clipboard's text to an agent (#236).
    let openHandoff: @MainActor () -> Void
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

/// The commands of the focused space and pane for the switcher (#346),
/// read where it opens: from inside its sheet they are out of reach.
struct PaletteSources {
    var space: [PaletteCommand]?
    var pane: [PaletteCommand]?
    var keySender: KeySender?
    var paneSearch: PaneSearchActions?
}

extension FocusedValues {
    @Entry var navigator: Navigator?
    /// Commands of the open space: tabs, worktree, rename, close (#346).
    @Entry var spaceCommands: [PaletteCommand]?
    /// Commands of the shown pane: conversation, voice, files, font (#346).
    @Entry var paneCommands: [PaletteCommand]?
    @Entry var tabNavigator: TabNavigator?
    @Entry var keySender: KeySender?
    @Entry var paneSearch: PaneSearchActions?
}

#if os(macOS)
/// "Nach Updates suchen …" in the app menu, below "Über Amiscara Agents".
struct UpdateCommands: Commands {
    @State private var updater = UpdaterController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable)
        }
    }
}

/// "Hilfe › Neuigkeiten" in place of the empty standard help item.
struct WhatsNewCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Neuigkeiten") {
                WhatsNewState.shared.showHistory()
                openWindow(id: WhatsNewWindow.id)
            }
        }
    }
}
#endif
