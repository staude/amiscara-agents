import SwiftUI

/// Draws a pane screen: one `Text` per line, styled runs as AttributedString.
/// Always dark, like most terminals, because agent TUIs pick their truecolor
/// values for a dark background.
struct TerminalScreenView: View {
    let content: PaneContent
    @AppStorage("terminalFontSize") private var fontSize = Platform.defaultTerminalFontSize

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            // A plain VStack: the visible screen is about 60 lines, and a
            // LazyVStack in a two-axis scroll view could stay undrawn until
            // the content changed (a black pane on the iPad).
            VStack(alignment: .leading, spacing: 0) {
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
        .defaultScrollAnchor(.bottomLeading)
        .defaultScrollAnchor(.bottomLeading, for: .sizeChanges)
        // A fresh scroll view per pane, so the previous pane's scroll
        // position cannot leave the new one out of sight.
        .id(content.paneId)
        .background(TerminalStyle.background)
        .environment(\.colorScheme, .dark)
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
