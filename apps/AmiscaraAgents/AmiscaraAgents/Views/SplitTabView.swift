import SwiftUI

/// A split tab on a wide screen: every pane where herdr draws it, each with
/// its own live screen. Tapping a pane selects it for the input bar. Only
/// the selected pane is read at full pace; the others refresh every few
/// seconds, because over SSH every read costs a round trip.
///
/// herdr's zoom is ignored on purpose: it is a view state of herdr's own
/// client, and the app has the room to show all panes.
struct SplitTabView: View {
    let connection: HostConnection
    let tab: TabItem
    let layout: SplitLayout
    @Binding var selection: String?

    var body: some View {
        GeometryReader { geometry in
            let scaleX = geometry.size.width / CGFloat(max(layout.columns, 1))
            let scaleY = geometry.size.height / CGFloat(max(layout.rows, 1))
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneId) { frame in
                    PaneTile(
                        connection: connection,
                        paneID: frame.paneId,
                        pane: tab.panes.first { $0.paneId == frame.paneId },
                        columns: frame.width,
                        isSelected: selection == frame.paneId
                    ) {
                        selection = frame.paneId
                    }
                    .padding(2)
                    .frame(
                        width: CGFloat(frame.width) * scaleX,
                        height: CGFloat(frame.height) * scaleY
                    )
                    .offset(x: CGFloat(frame.x) * scaleX, y: CGFloat(frame.y) * scaleY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(.background.secondary)
    }
}

/// One pane of a split tab: a small header and the screen.
private struct PaneTile: View {
    let connection: HostConnection
    let paneID: String
    let pane: PaneItem?
    let columns: UInt32
    let isSelected: Bool
    let select: () -> Void
    @State private var model = PaneModel()
    /// Only the selected tile searches, like only it loads history; ⌘F and
    /// ⌘G act on it.
    @State private var search = PaneSearchState()
    @AppStorage(PaneModel.wrapLinesKey) private var wrapLines = false

    var body: some View {
        let matches = isSelected ? search.matches(in: model.content) : []
        return VStack(spacing: 0) {
            header
            if isSelected, search.isOpen {
                PaneSearchBar(state: search, matches: matches)
                    .font(.callout)
                    .background(Material.paneBar)
            }
            screen(search: search.highlight(matches))
        }
        // A background view, so selecting a tile does not change the tile's
        // own identity (and with it its follower).
        .background {
            if isSelected {
                Color.clear.focusedSceneValue(\.paneSearch, search.actions(matches))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
        }
        // Simultaneous, so scrolling and text selection in the screen still work.
        .simultaneousGesture(TapGesture().onEnded(select))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onChange(of: connection.generation, initial: true) {
            model.show(paneID: paneID, on: connection, live: isSelected)
        }
        .onChange(of: isSelected) { _, selected in
            model.setLive(selected)
            if !selected { search.close() }
        }
        .onChange(of: wrapLines, initial: true) { model.setUnwrap(wrapLines) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(state: pane?.agent == nil ? nil : pane?.agentState)
            Text(pane.map { $0.title.isEmpty ? $0.paneId : $0.title } ?? paneID)
                .lineLimit(1)
                .truncationMode(.middle)
            if let agent = pane?.agent {
                Text(agent).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let state = pane?.agentState, pane?.agent != nil {
                Text(state.label).foregroundStyle(state.color).lineLimit(1)
            }
            if isSelected {
                SelectTextButton(title: pane.map { $0.title.isEmpty ? $0.paneId : $0.title } ?? paneID) {
                    model.content?.plainText ?? ""
                }
                .disabled(model.content == nil)
                PaneSearchButton(state: search)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .background(Material.paneBar)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    @ViewBuilder
    private func screen(search: SearchHighlight) -> some View {
        if let content = model.content {
            TerminalScreenView(content: content, history: isSelected ? model : nil, fitColumns: columns, search: search)
                .overlay(alignment: .top) {
                    if let error = model.error {
                        Banner(text: error, systemImage: "exclamationmark.triangle")
                    } else if !connection.isLive {
                        Banner(text: String(localized: "Verbindung unterbrochen, Inhalt veraltet"), systemImage: "wifi.slash")
                    }
                }
        } else if let error = model.error {
            ContentUnavailableView("Pane nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            TerminalThemeReader { _ in
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension Material {
    /// The material of headers and bars; tvOS has no `.bar`.
    static var paneBar: Material {
        #if os(tvOS)
        .regularMaterial
        #else
        .bar
        #endif
    }
}
