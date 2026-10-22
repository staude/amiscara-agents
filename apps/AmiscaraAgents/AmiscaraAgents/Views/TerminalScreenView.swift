import SwiftUI

/// Draws a pane screen: one `Text` per line, styled runs as AttributedString.
/// Colors from the terminal settings (`TerminalTheme`).
struct TerminalScreenView: View {
    let content: PaneContent
    /// Scrollback controls above the first line; `nil` hides them.
    var history: PaneModel?
    /// For a pane in a split tab: shrink the font until this many terminal
    /// columns fit the width, down to a still readable minimum.
    var fitColumns: UInt32?
    /// Search matches to mark; empty when no search is open. Covers loaded
    /// history too, since it is part of `content`.
    var search = SearchHighlight()
    @AppStorage("terminalFontSize") private var preferredFontSize = Platform.defaultTerminalFontSize
    /// Long lines wrap at the view width instead of scrolling sideways (#191).
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false
    @State private var width: CGFloat = 0
    /// Set once the user scrolled, so the first layout (which may briefly sit
    /// at the top before the bottom anchor applies) cannot load history.
    @State private var userScrolled = false
    #if os(tvOS)
    /// Line in the middle of the view while scrolling with the Siri Remote;
    /// `nil` sits at the bottom like a terminal.
    @State private var remoteLine: Int?
    @FocusState private var focused: Bool
    /// Lines per swipe on the remote.
    private static let remoteStep = 12
    #endif

    private var fontSize: Double {
        guard let fitColumns, fitColumns > 0, width > 0 else { return preferredFontSize }
        // A monospaced glyph is about 0.6 em wide; 20 is the padding.
        let fitting = (Double(width) - 20) / (Double(fitColumns) * 0.6)
        return min(preferredFontSize, max(7, fitting.rounded(.down)))
    }

    var body: some View {
        TerminalThemeReader { theme in
            lines(theme)
        }
    }

    private func lines(_ theme: TerminalTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
                // A plain VStack: the visible screen is about 60 lines, and a
                // LazyVStack in a two-axis scroll view could stay undrawn until
                // the content changed (a black pane on the iPad). With history
                // it holds up to 1000 lines, which SwiftUI still lays out fast.
                VStack(alignment: .leading, spacing: 0) {
                    if let history {
                        HistoryHeader(model: history, content: content, theme: theme)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(content.lines.enumerated()), id: \.offset) { index, line in
                        let text = Text(TerminalStyle.attributed(
                            line,
                            theme: theme,
                            fontSize: fontSize,
                            matches: search.byLine[index] ?? [],
                            current: search.current
                        ))
                        if !wrapLines {
                            text
                                .fixedSize()
                                .frame(minHeight: fontSize * 1.25, alignment: .leading)
                        } else if line.isRule {
                            // A frame would break apart: clip it instead.
                            text
                                .fixedSize()
                                .frame(maxWidth: .infinity, minHeight: fontSize * 1.25, alignment: .leading)
                                .clipped()
                        } else {
                            text
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: fontSize * 1.25, alignment: .leading)
                        }
                    }
                }
                .padding(10)
                .selectableText()
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
            .onChange(of: search.scrollRequest) {
                guard let line = search.current?.line else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.5))
                }
            }
            #if os(tvOS)
            // The remote scrolls by focus: the terminal takes it and turns
            // swipes up and down into jumps of a few lines (#128).
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                let last = max(content.lines.count - 1, 0)
                let current = remoteLine ?? last
                switch direction {
                case .up: remoteLine = max(current - Self.remoteStep, 0)
                case .down: remoteLine = min(current + Self.remoteStep, last)
                default: return
                }
                userScrolled = true
                if remoteLine == 0 { history?.loadMoreHistory() }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(remoteLine, anchor: UnitPoint(x: 0, y: 0.5))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .onChange(of: content.paneId) { remoteLine = nil }
            #endif
        }
    }
}

/// First row of the pane: load older lines, or say why there are none.
private struct HistoryHeader: View {
    let model: PaneModel
    let content: PaneContent
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 12) {
            if model.isLoadingHistory {
                ProgressView().controlSize(.small)
                Text("Verlauf wird geladen …")
            } else if model.canLoadMoreHistory {
                Button("Älteren Verlauf laden", systemImage: "arrow.up.to.line") {
                    model.loadMoreHistory()
                }
            } else if model.hasNoHistory {
                Text("Kein Verlauf: Bei Vollbild-Programmen wie Claude Code speichert herdr keinen.")
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
        .foregroundStyle(theme.foreground.color.opacity(0.7))
        .fixedSize()
    }
}

enum TerminalStyle {
    static let match = Color(red: 0.95, green: 0.80, blue: 0.25).opacity(0.75)
    static let currentMatch = Color(red: 1.00, green: 0.55, blue: 0.10)

    static func attributed(
        _ line: StyledLine,
        theme: TerminalTheme,
        fontSize: Double,
        matches: [SearchMatch] = [],
        current: SearchMatch? = nil
    ) -> AttributedString {
        var result = AttributedString()
        for span in line.spans {
            var part = AttributedString(span.text)
            var fg = rgb(span.fg, theme)
            var bg = rgb(span.bg, theme)
            if span.inverse {
                swap(&fg, &bg)
                fg = fg ?? theme.background
                bg = bg ?? theme.foreground
            }
            var foreground = theme.readable(fg ?? theme.foreground, on: bg ?? theme.background).color
            if span.dim { foreground = foreground.opacity(0.55) }
            if span.hidden { foreground = .clear }
            part.foregroundColor = foreground
            if let bg { part.backgroundColor = bg.color }
            part.font = .system(size: fontSize, weight: span.bold ? .bold : .regular, design: .monospaced)
                .italic(span.italic)
            if span.underline { part.underlineStyle = .single }
            if span.strikethrough { part.strikethroughStyle = .single }
            #if !os(tvOS)
            // A web address in the output opens in the browser (#186).
            if let link = span.link, let url = URL(string: link) {
                part.link = url
                part.underlineStyle = .single
            }
            #endif
            result += part
        }
        for match in matches {
            let chars = result.characters
            guard let start = chars.index(chars.startIndex, offsetBy: match.start, limitedBy: chars.endIndex),
                  let end = chars.index(start, offsetBy: match.length, limitedBy: chars.endIndex)
            else { continue }
            result[start..<end].backgroundColor = match == current ? currentMatch : Self.match
            result[start..<end].foregroundColor = .black
        }
        return result
    }

    static func rgb(_ color: TermColor, _ theme: TerminalTheme) -> RGB? {
        switch color {
        case .default:
            return nil
        case .rgb(let r, let g, let b):
            return RGB(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        case .indexed(let index):
            return indexed(Int(index), theme)
        }
    }

    /// xterm palette: 16 base colors from the theme, 6x6x6 cube, 24 greys.
    private static func indexed(_ index: Int, _ theme: TerminalTheme) -> RGB {
        switch index {
        case 0..<16:
            return theme.base[index]
        case 16..<232:
            let n = index - 16
            let level = { (v: Int) in v == 0 ? 0.0 : (Double(v) * 40 + 55) / 255 }
            return RGB(level(n / 36), level(n / 6 % 6), level(n % 6))
        default:
            let v = (Double(index - 232) * 10 + 8) / 255
            return RGB(v, v, v)
        }
    }
}

extension StyledLine {
    /// A row drawn only with box-drawing and block characters, such as a
    /// frame or a rule of a full-screen program: wrapping would break it
    /// apart, so a wrapping view clips it instead (#191).
    var isRule: Bool {
        var hasBox = false
        for span in spans {
            for scalar in span.text.unicodeScalars {
                if (0x2500...0x259F).contains(scalar.value) {
                    hasBox = true
                } else if !CharacterSet.whitespaces.contains(scalar) {
                    return false
                }
            }
        }
        return hasBox
    }
}
