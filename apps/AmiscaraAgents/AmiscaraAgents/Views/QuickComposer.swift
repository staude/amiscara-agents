#if os(macOS)
import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// ⌃⌥Space: ⌥⌘Space opens the Finder search window (#307).
    @MainActor static let quickComposer = Self("quickComposer", default: .init(.space, modifiers: [.control, .option]))
}

/// The quick composer (#307): a floating window like Spotlight for a prompt
/// to the last agent, from any app. It does not activate the app, so the
/// other app stays in front and the main window behind.
@MainActor
final class QuickComposer {
    static let shared = QuickComposer()

    private var panel: QuickComposerPanel?

    /// The global shortcut: opens the window, or closes it when open.
    func toggle(store: HostStore) {
        if let panel, panel.isVisible {
            close()
            return
        }
        // The lock follows the app's activation, which this window skips.
        let lock = AppLock.shared
        lock.checkWithoutActivation()
        if lock.isCovered {
            // Activating asks for the owner (AppLock.becameActive).
            if !AppLockCurtain.shared.bringToFront() { NSApp.activate() }
            return
        }
        let panel = QuickComposerPanel()
        // Each opening starts empty, with the target found anew.
        let hosting = NSHostingView(rootView: QuickComposerView().environment(store))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.place()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        // Cleared first: ordering out resigns key, which closes again.
        let panel = panel
        self.panel = nil
        panel?.orderOut(nil)
    }
}

/// Takes keys without activating the app; closes on a click elsewhere.
private final class QuickComposerPanel: NSPanel {
    static let width: CGFloat = 560

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        QuickComposer.shared.close()
    }

    /// Centered, in the upper third of the screen with the mouse pointer.
    func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            center()
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameTopLeftPoint(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height / 3 + size.height / 2
        ))
    }
}

/// "Prompt an <Agent>": the target with a list to switch it, the text
/// field and the key bar's Esc and ⌃C. Return sends, Esc closes. No live
/// mode, attachments or dictation.
private struct QuickComposerView: View {
    @Environment(HostStore.self) private var store

    @State private var target: SpaceRef?
    @State private var text = ""
    @State private var choosing = false
    @State private var sending = false
    @State private var error: String?
    @FocusState private var textFocused: Bool

    var body: some View {
        let entry = target.flatMap(entry(for:))
        VStack(alignment: .leading, spacing: 10) {
            Button {
                choosing.toggle()
            } label: {
                header(entry)
            }
            .buttonStyle(.plain)
            // In the window, not a popover: a popover is a window of its
            // own, takes the keys and would close this one.
            if choosing || target == nil {
                QuickComposerAgentList { picked in
                    target = picked
                    error = nil
                    choosing = false
                    textFocused = true
                }
            } else {
                TextField("Prompt", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...6)
                    .focused($textFocused)
                    .disabled(sending)
                    .onSubmit(send)
                HStack(spacing: 6) {
                    key("Esc", "esc", help: "Esc (⌘.)")
                        .keyboardShortcut(".", modifiers: .command)
                    key("⌃C", "ctrl+c", help: "Control-C (⌃C)")
                        .keyboardShortcut("c", modifiers: .control)
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: QuickComposerPanel.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // Esc closes the list, then the window, wherever the focus is.
            Button("Schließen") {
                if choosing && target != nil {
                    choosing = false
                    textFocused = true
                } else {
                    QuickComposer.shared.close()
                }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            // Without a still valid last agent the list shows; no guessing.
            target = lastAgent()
            textFocused = target != nil
        }
    }

    private func header(_ entry: SwitcherEntry?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane")
                .foregroundStyle(.secondary)
            if let entry {
                Text("Prompt an \(entry.title)")
                    .font(.headline)
                    .lineLimit(1)
                Text([entry.subtitle, entry.hostName].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Agent wählen")
                    .font(.headline)
            }
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func key(_ title: String, _ key: String, help: String) -> some View {
        Button(title) { send(keys: [key]) }
            .controlSize(.small)
            .help(help)
            .disabled(!canInput)
    }

    /// The last agent while it is still the same one in its pane and its
    /// host is live.
    private func lastAgent() -> SpaceRef? {
        guard let last = LastAgent.current,
              let connection = store.connection(for: last.hostID), connection.isLive,
              last.matches(store.boardItem(host: last.hostID, pane: last.paneID))
        else { return nil }
        return SpaceRef(hostID: last.hostID, workspaceID: last.workspaceID, paneID: last.paneID)
    }

    private func entry(for target: SpaceRef) -> SwitcherEntry? {
        SwitcherEntry.all(in: store).first {
            $0.kind == .agent && $0.target.hostID == target.hostID && $0.target.paneID == target.paneID
        }
    }

    private var canInput: Bool {
        guard let target, let connection = store.connection(for: target.hostID) else { return false }
        return connection.config.inputAllowed && !sending
    }

    private func send() {
        guard let target, let paneID = target.paneID, !sending,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                // Remembers the target as the last agent.
                try await store.sendPrompt(text, toHost: target.hostID, pane: paneID)
                QuickComposer.shared.close()
            } catch let failure as PromptIntentError {
                error = String(localized: failure.localizedStringResource)
                textFocused = true
            } catch {
                self.error = inputErrorMessage(error)
                textFocused = true
            }
        }
    }

    private func send(keys: [String]) {
        guard let target, let paneID = target.paneID,
              let connection = store.connection(for: target.hostID)
        else { return }
        Task {
            do {
                try await connection.send(keys: keys, to: paneID)
                error = nil
            } catch {
                self.error = inputErrorMessage(error)
            }
            textFocused = true
        }
    }
}

/// The agents of all hosts to switch the target, searched as in ⌘K.
private struct QuickComposerAgentList: View {
    @Environment(HostStore.self) private var store
    let onPick: (SpaceRef) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let agents = SwitcherEntry.all(in: store).filter { $0.kind == .agent }
        let results = SwitcherMatch.filter(agents, query: query)
        let showHost = store.connections.count > 1
        VStack(spacing: 0) {
            TextField("Agent suchen", text: $query)
                .technicalInput()
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { pick(current(in: results)) }
                .onKeyPress(.downArrow) { move(1, in: results) }
                .onKeyPress(.upArrow) { move(-1, in: results) }
                .padding(.bottom, 8)
            Divider()
            if results.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("Keine Agents", systemImage: "sparkles")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                ScrollViewReader { proxy in
                    List(results) { entry in
                        Button {
                            pick(entry)
                        } label: {
                            SwitcherRow(entry: entry, showHost: showHost)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            entry.id == current(in: results)?.id ? Color.accentColor.opacity(0.2) : Color.clear
                        )
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onChange(of: query) { highlighted = nil }
        .onAppear { searchFocused = true }
        .frame(height: 280)
    }

    /// The highlighted entry, or the best match when nothing was moved yet.
    private func current(in results: [SwitcherEntry]) -> SwitcherEntry? {
        results.first { $0.id == highlighted } ?? results.first
    }

    private func move(_ step: Int, in results: [SwitcherEntry]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let index = results.firstIndex { $0.id == current(in: results)?.id } ?? 0
        highlighted = results[min(max(index + step, 0), results.count - 1)].id
        return .handled
    }

    private func pick(_ entry: SwitcherEntry?) {
        guard let entry else { return }
        onPick(entry.target)
    }
}
#endif
