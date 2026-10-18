import SwiftUI

/// Font size of the pane screen. One value for all panes, kept across
/// launches under the key `TerminalScreenView` reads. Pinch, the menu
/// commands and the header menu all go through here, so they share the
/// limits and the step.
enum TerminalZoom {
    static let storageKey = "terminalFontSize"
    static let range: ClosedRange<Double> = 8...28
    static let step = 1.0

    static func clamped(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }

    static func larger(_ size: Double) -> Double {
        clamped((size + step).rounded())
    }

    static func smaller(_ size: Double) -> Double {
        clamped((size - step).rounded())
    }
}

extension View {
    /// Pinch to change the terminal font size, live while the fingers move.
    func terminalZoomGesture() -> some View {
        modifier(TerminalZoomGesture())
    }
}

/// Simultaneous with the scroll view's own gestures: a one or two finger
/// pan still scrolls, only a spread or pinch changes the size. The scroll
/// view keeps its bottom anchor on size changes, so the latest output stays
/// in sight while the text grows.
private struct TerminalZoomGesture: ViewModifier {
    @AppStorage(TerminalZoom.storageKey) private var fontSize = Platform.defaultTerminalFontSize
    /// The size when the pinch began; magnification is relative to it.
    @State private var pinchStart: Double?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? fontSize
                    pinchStart = start
                    // Half points: smooth enough to feel live, and the
                    // screen is not redrawn for every tiny finger movement.
                    let size = TerminalZoom.clamped((start * value.magnification * 2).rounded() / 2)
                    if size != fontSize { fontSize = size }
                }
                .onEnded { _ in pinchStart = nil }
        )
    }
}

/// Larger, smaller and reset as buttons. Used in the app's View menu, where
/// they carry ⌘+ / ⌘- / ⌘0 (Mac, and iPad with a hardware keyboard), and in
/// the pane header's menu, so the size can be found without gestures.
struct TerminalZoomButtons: View {
    @AppStorage(TerminalZoom.storageKey) private var fontSize = Platform.defaultTerminalFontSize
    var withShortcuts = false

    var body: some View {
        Button("Schrift größer", systemImage: "textformat.size.larger") {
            fontSize = TerminalZoom.larger(fontSize)
        }
        .keyboardShortcut(withShortcuts ? KeyboardShortcut("+", modifiers: .command) : nil)
        .disabled(fontSize >= TerminalZoom.range.upperBound)

        Button("Schrift kleiner", systemImage: "textformat.size.smaller") {
            fontSize = TerminalZoom.smaller(fontSize)
        }
        .keyboardShortcut(withShortcuts ? KeyboardShortcut("-", modifiers: .command) : nil)
        .disabled(fontSize <= TerminalZoom.range.lowerBound)

        Button("Originalgröße", systemImage: "arrow.counterclockwise") {
            fontSize = Platform.defaultTerminalFontSize
        }
        .keyboardShortcut(withShortcuts ? KeyboardShortcut("0", modifiers: .command) : nil)
        .disabled(fontSize == Platform.defaultTerminalFontSize)
    }
}

/// The header's "Aa" menu with the zoom buttons and the current size.
struct TerminalZoomMenu: View {
    @AppStorage(TerminalZoom.storageKey) private var fontSize = Platform.defaultTerminalFontSize

    var body: some View {
        Menu {
            TerminalZoomButtons()
            Divider()
            Text("Schriftgröße \(fontSize, format: .number.precision(.fractionLength(0...1))) pt")
        } label: {
            Label("Schriftgröße", systemImage: "textformat.size")
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .help("Schriftgröße")
    }
}

/// ⌘+ / ⌘- / ⌘0 in the View menu. On the iPad the same items show up in
/// the menu bar and the hardware keyboard shortcut overlay.
struct TerminalZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            TerminalZoomButtons(withShortcuts: true)
        }
    }
}
