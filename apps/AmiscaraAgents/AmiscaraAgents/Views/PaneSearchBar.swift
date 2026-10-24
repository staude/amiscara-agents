import SwiftUI

/// Find field above a pane screen. ⌘F, ⌘G and ⇧⌘G are menu commands
/// (`AppCommands`), so they reach the pane wherever the focus is; Return in
/// the field also goes to the next match, Esc closes.
struct PaneSearchBar: View {
    @Bindable var state: PaneSearchState
    let matches: [SearchMatch]
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("In der Pane suchen", text: $state.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    state.step(1, in: matches)
                    focused = true
                }
            if !state.query.isEmpty {
                if let index = state.currentIndex(matches) {
                    Text("\(index + 1) von \(matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Keine Treffer").foregroundStyle(.secondary)
                }
            }
            Button("Vorheriger Treffer", systemImage: "chevron.up") { state.step(-1, in: matches) }
                .disabled(matches.isEmpty)
            Button("Nächster Treffer", systemImage: "chevron.down") { state.step(1, in: matches) }
                .disabled(matches.isEmpty)
            Button("Suche schließen", systemImage: "xmark.circle.fill", action: state.close)
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
        .onChange(of: state.focusRequest) { focused = true }
    }
}

/// The magnifier in a pane header: opens the search like ⌘F and closes it
/// again, a larger target than the bar's own close button.
struct PaneSearchButton: View {
    let state: PaneSearchState

    var body: some View {
        #if os(tvOS)
        // tvOS has no button style for toggles.
        Button("Suchen", systemImage: "magnifyingglass") {
            state.isOpen ? state.close() : state.open()
        }
        .labelStyle(.iconOnly)
        #else
        Toggle("Suchen", systemImage: "magnifyingglass", isOn: Binding(
            get: { state.isOpen },
            set: { $0 ? state.open() : state.close() }
        ))
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("In der Pane suchen (⌘F)")
        #endif
    }
}
