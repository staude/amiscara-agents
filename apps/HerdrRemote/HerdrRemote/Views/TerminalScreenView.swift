import SwiftUI

/// Draws a pane screen: one `Text` per line, styled runs as AttributedString.
/// Always dark, like most terminals, because agent TUIs pick their truecolor
/// values for a dark background.
struct TerminalScreenView: View {
    let content: PaneContent
    /// Scrollback controls above the first line; `nil` hides them.
    var history: PaneModel?
    /// For a pane in a split tab: shrink the font until this many terminal
    /// columns fit the width, down to a still readable minimum.
    var fitColumns: UInt32?
    @AppStorage("terminalFontSize") private var preferredFontSize = Platform.defaultTerminalFontSize
    @State private var width: CGFloat = 0
    /// Set once the user scrolled, so the first layout (which may briefly sit
    /// at the top before the bottom anchor applies) cannot load history.
    @State private var userScrolled = false

    private var fontSize: Double {
        guard let fitColumns, fitColumns > 0, width > 0 else { return preferredFontSize }
        // A monospaced glyph is about 0.6 em wide; 20 is the padding.
        let fitting = (Double(width) - 20) / (Double(fitColumns) * 0.6)
        return min(preferredFontSize, max(7, fitting.rounded(.down)))
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            // A plain VStack: the visible screen is about 60 lines, and a
            // LazyVStack in a two-axis scroll view could stay undrawn until
            // the content changed (a black pane on the iPad). With history
            // it holds up to 1000 lines, which SwiftUI still lays out fast.
            VStack(alignment: .leading, spacing: 0) {
                if let history {
                    HistoryHeader(model: history, content: content)
                        .padding(.bottom, 8)
                }
                ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                    Text(TerminalStyle.attributed(line, fontSize: fontSize))
                        .fixedSize()
                        .frame(minHeight: fontSize * 1.25, alignment: .leading)
                }
            }
            .padding(10)
            .textSelection(.enabled)
        }
        // Like a terminal: start at the bottom, where the latest output and
        // the agent's prompt are, and stay there when new lines arrive.
        // Older lines loaded above keep the lines in view where they are.
        .defaultScrollAnchor(.bottomLeading)
        .defaultScrollAnchor(.bottomLeading, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            if phase.isScrolling { userScrolled = true }
        }
        // Scrolling up to the first line loads the next history step, like
        // a terminal's scrollback.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.containerSize.height
                && geometry.contentOffset.y <= geometry.contentInsets.top + 24
        } action: { _, atTop in
            if atTop, userScrolled { history?.loadMoreHistory() }
        }
        // A fresh scroll view per pane, so the previous pane's scroll
        // position cannot leave the new one out of sight.
        .id(content.paneId)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(TerminalStyle.background)
        .environment(\.colorScheme, .dark)
    }
}

/// First row of the pane: load older lines, or say why there are none.
private struct HistoryHeader: View {
    let model: PaneModel
    let content: PaneContent

    var body: some View {
        HStack(spacing: 12) {
            if model.isLoadingHistory {
                ProgressView().controlSize(.small)
                Text("Verlauf wird geladen …")
            } else if model.canLoadMoreHistory {
                Button("Älteren Verlauf laden", systemImage: "arrow.up.to.line") {
                    model.loadMoreHistory()
                }
            } else if content.historyLines > 0, content.truncated {
                Text("Mehr als \(content.historyLines) Zeilen liefert herdr nicht.")
            } else if content.historyLines > 0 {
                Text("Anfang des Verlaufs")
            }
            if content.historyLines > 0 {
                Button("Nur Bildschirm", systemImage: "rectangle.compress.vertical") {
                    model.hideHistory()
                }
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .foregroundStyle(TerminalStyle.foreground.opacity(0.7))
        .fixedSize()
    }
}

enum TerminalStyle {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let foreground = Color(red: 0.88, green: 0.88, blue: 0.88)

    static func attributed(_ line: StyledLine, fontSize: Double) -> AttributedString {
        var result = AttributedString()
        for span in line.spans {
            var part = AttributedString(span.text)
            var fg = color(span.fg)
            var bg = color(span.bg)
            if span.inverse {
                swap(&fg, &bg)
                fg = fg ?? background
                bg = bg ?? foreground
            }
            var foreground = fg ?? Self.foreground
            if span.dim { foreground = foreground.opacity(0.55) }
            if span.hidden { foreground = .clear }
            part.foregroundColor = foreground
            if let bg { part.backgroundColor = bg }
            part.font = .system(size: fontSize, weight: span.bold ? .bold : .regular, design: .monospaced)
                .italic(span.italic)
            if span.underline { part.underlineStyle = .single }
            if span.strikethrough { part.strikethroughStyle = .single }
            result += part
        }
        return result
    }

    static func color(_ color: TermColor) -> Color? {
        switch color {
        case .default:
            return nil
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let index):
            return indexed(Int(index))
        }
    }

    /// xterm palette: 16 base colors, 6x6x6 cube, 24 greys.
    private static func indexed(_ index: Int) -> Color {
        switch index {
        case 0..<16:
            let (r, g, b) = base[index]
            return Color(red: r, green: g, blue: b)
        case 16..<232:
            let n = index - 16
            let level = { (v: Int) in v == 0 ? 0.0 : (Double(v) * 40 + 55) / 255 }
            return Color(red: level(n / 36), green: level(n / 6 % 6), blue: level(n % 6))
        default:
            let v = (Double(index - 232) * 10 + 8) / 255
            return Color(red: v, green: v, blue: v)
        }
    }

    private static let base: [(Double, Double, Double)] = [
        (0.00, 0.00, 0.00), (0.80, 0.24, 0.24), (0.36, 0.72, 0.36), (0.80, 0.68, 0.24),
        (0.26, 0.46, 0.84), (0.69, 0.36, 0.78), (0.24, 0.68, 0.74), (0.80, 0.80, 0.80),
        (0.46, 0.46, 0.46), (0.96, 0.40, 0.40), (0.52, 0.88, 0.52), (0.96, 0.86, 0.40),
        (0.46, 0.64, 0.98), (0.86, 0.52, 0.96), (0.42, 0.86, 0.92), (1.00, 1.00, 1.00),
    ]
}
