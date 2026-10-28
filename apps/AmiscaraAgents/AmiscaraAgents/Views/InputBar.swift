import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Input under the pane screen: one-tap answers while an agent waits, a key
/// bar, and a composer. Answers appear only here, next to the screen they
/// answer, never blind from the board.
struct InputBar: View {
    let connection: HostConnection
    let pane: PaneItem
    /// The choice question the agent asks on the screen (#272): its options
    /// replace the buttons 1, 2, 3.
    var question: ChoiceQuestion?

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var attachments: [ImageAttachment] = []
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var importingFiles = false
    /// Something is dragged over the input bar.
    @State private var dropTargeted = false
    @State private var choosingPhotos = false
    @FocusState private var composerFocused: Bool
    @Environment(HostStore.self) private var store
    @State private var dictation = Dictation()
    /// Composer text from before dictation started; the transcript follows it.
    @State private var textBeforeDictation = ""
    /// The iPhone Duo's vertical bar is shown; the microphone moves there.
    @State private var verticalBar = false
    @State private var editingQuickReplies = false
    @State private var showingHistory = false
    private let history = PromptHistory.shared
    /// Live mode: while an agent's composer starts with "/", or after a
    /// suggestion was taken with Tab, every change goes straight into the
    /// agent's own input line, so Claude Code shows its suggestions in the
    /// pane. `liveTyped` is what that line got from the composer.
    @State private var liveTyped = ""
    @State private var liveAfterTab = false
    /// Live input in order, without blocking the bar like `perform`.
    @State private var liveQueue: Task<Void, Never>?
    private let quickReplies = QuickReplyStore.shared
    #if os(macOS)
    /// Key monitor for ⌘V in the composer, see `catchImagePaste`.
    @State private var pasteMonitor: Any?
    #endif

    #if os(iOS)
    /// The on-screen keyboard is up; with a hardware keyboard it is not.
    @State private var keyboardShown = false
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    #endif
    private var isAgent: Bool { pane.agent != nil }
    /// Waits for an answer: herdr says so, or a choice question is on the
    /// screen, which herdr may report late (#272).
    private var isBlocked: Bool { isAgent && (pane.agentState == .blocked || question != nil) }
    /// Never while the agent waits for approval: typed keys would answer
    /// its dialog.
    private var isLive: Bool {
        isAgent && !isBlocked && attachments.isEmpty
            && (text.hasPrefix("/") || liveAfterTab || !liveTyped.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBlocked {
                answerRow
            }
            quickReplyRow
            keyRow
            if !attachments.isEmpty {
                attachmentRow
            }
            if isLive {
                Label("Live an \(pane.agent ?? "Agent"): ↑↓ wählen, Tab übernimmt, Enter führt aus", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            composer
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .selectableText()
            }
        }
        .padding(10)
        .disabled(sending || !connection.isLive)
        // Keyboard shortcuts for the key bar, see AppCommands.
        .focusedSceneValue(\.keySender, connection.isLive ? KeySender(send: { send(keys: $0) }, isBlocked: isBlocked) : nil)
        .onChange(of: dictation.error) { _, message in
            if let message { error = message }
        }
        .onChange(of: dictation.transcript) { _, spoken in
            guard dictation.isRunning || !spoken.isEmpty else { return }
            let base = textBeforeDictation.trimmingCharacters(in: .whitespaces)
            text = base.isEmpty ? spoken : base + " " + spoken
        }
        .onDisappear { dictation.stop() }
        // "Dictate to the last agent" from Control Center (#227).
        // Not behind the app lock (#232): once it is unlocked.
        .modifier(RequestedDictation(
            request: store.notifier.dictateRequest,
            covered: AppLock.shared.isCovered,
            start: startRequestedDictation
        ))
        .toolbar {
            if verticalBar {
                ToolbarItem(placement: .primaryAction) { dictationButton }
            }
        }
        .tracksVerticalBar($verticalBar)
        // ⌘V with images that the focused text view does not take itself
        // (iOS: a plain text view passes image pastes on).
        .pasteDestination(for: PastedImage.self) { images in
            addPasted(images.map { ImageAttachment.make(data: $0.data, type: $0.type) })
        }
        #if os(macOS)
        .onAppear(perform: catchImagePaste)
        .onDisappear(perform: releaseImagePaste)
        // The monitor holds this view's values; renew it for another host.
        .onChange(of: connection.id) {
            releaseImagePaste()
            catchImagePaste()
        }
        #endif
        // The key, not only the pane: two hosts may use the same pane id.
        .onChange(of: draftKey) {
            dictation.stop()
            text = ""
            error = nil
            attachments = []
            takePendingShare()
            takeHostFiles()
        }
        // Folding an iPhone Duo or resizing a window can swap this bar for
        // a new one; the composer goes along (#215).
        .onAppear {
            if let draft = ComposerDraft.slot, draft.key == draftKey {
                text = draft.text
                attachments = draft.attachments
            }
            takePendingShare()
            takeHostFiles()
        }
        #if os(iOS)
        // A share for this pane while the bar is on screen (#225).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            takePendingShare()
        }
        #endif
        // On the Mac too: its share extension and the handoff sheet (#236).
        .onReceive(NotificationCenter.default.publisher(for: PendingShare.arrived)) { _ in
            takePendingShare()
        }
        // A file sent from the file browser (#271).
        .onReceive(NotificationCenter.default.publisher(for: ComposerInbox.arrived)) { _ in
            takeHostFiles()
        }
        .onChange(of: text) { keepDraft() }
        .onChange(of: attachments.map(\.id)) { keepDraft() }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        // Files and screenshots dropped anywhere on the input bar (#116).
        .onDrop(of: [.fileURL, .image, .item], isTargeted: $dropTargeted) { providers in
            Task { await addDropped(providers) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        // Presented from the view, not as a PhotosPicker inside the Menu,
        // which often does not open on iOS.
        .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, maxSelectionCount: 5, matching: .images)
        .sheet(isPresented: $editingQuickReplies) {
            QuickReplyEditor(store: quickReplies)
        }
        .sheet(isPresented: $showingHistory) {
            PromptHistoryView(history: history, key: historyKey) { prompt in
                text = prompt
                composerFocused = true
            }
        }
    }

    /// Dictation a control asked for (#227), for this pane, fresh, and not
    /// while the app lock covers the app.
    private func startRequestedDictation() {
        guard let request = store.notifier.dictateRequest,
              request.hostID == connection.id, request.paneID == pane.paneId
        else { return }
        guard request.isFresh else {
            store.notifier.dictateRequest = nil
            return
        }
        guard !AppLock.shared.isCovered else { return }
        store.notifier.dictateRequest = nil
        if !dictation.isRunning { toggleDictation() }
    }

    private var draftKey: String { ComposerInbox.key(hostID: connection.id, paneID: pane.paneId) }

    /// Text and images shared to this pane from another app (#225), or a
    /// handoff as a Markdown file (#236): into the composer, not sent.
    private func takePendingShare() {
        guard let pending = PendingShare.take(hostID: connection.id, paneID: pane.paneId) else { return }
        let shared = pending.share.text
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let handoff = pending.share.handoff {
            takeHandoff(handoff, prompt: shared, created: pending.share.created, current: current)
            return
        }
        text = current.isEmpty ? shared : current + "\n" + shared
        guard !pending.images.isEmpty else { return }
        guard connection.config.uploadAllowed else {
            error = String(localized: "Die geteilten Bilder fehlen: Bilder hochladen ist für \(connection.config.name) aus.")
            return
        }
        let images = pending.images.map { ImageAttachment.make(data: $0, type: nil) }
        attachments.append(contentsOf: images.compactMap { $0 })
        if images.contains(where: { $0 == nil }) {
            error = String(localized: "Ein geteiltes Bild konnte nicht gelesen werden.")
        }
    }

    /// The handoff as `handoff-<date>.md`, the prompt in the composer; the
    /// file's path follows the prompt on its own line when it is sent. With
    /// upload off the text itself goes into the composer.
    private func takeHandoff(_ handoff: String, prompt: String, created: Date, current: String) {
        let attachment = connection.config.uploadAllowed
            ? try? ImageAttachment.file(data: Data(handoff.utf8), name: Handoff.fileName(at: created))
            : nil
        guard let attachment else {
            // The prompt speaks of a file; without one the text stands alone.
            text = [current, handoff].filter { !$0.isEmpty }.joined(separator: "\n")
            error = connection.config.uploadAllowed
                ? String(localized: "Die Übergabe ist zu groß für eine Datei; der Text steht im Eingabefeld.")
                : String(localized: "Hochladen ist für \(connection.config.name) aus; der Text steht im Eingabefeld.")
            return
        }
        text = current.isEmpty ? prompt : current + "\n" + prompt
        attachments.append(attachment)
    }

    /// Files on the host sent from the file browser (#271): attached by
    /// path, each once, and the composer focused for the prompt.
    private func takeHostFiles() {
        let paths = ComposerInbox.take(key: draftKey)
        guard !paths.isEmpty else { return }
        for path in paths where !attachments.contains(where: { $0.hostPath == path }) {
            attachments.append(.hostFile(path: path))
        }
        composerFocused = true
    }

    private var historyKey: String { PromptHistory.key(host: connection.id, pane: pane.paneId) }

    private func keepDraft() {
        ComposerDraft.slot = (draftKey, text, attachments)
    }

    /// Saved prompts, one tap sends. Scrolls sideways so it fits an iPhone.
    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(quickReplies.usable) { reply in
                    Button {
                        send(quickReply: reply.trimmed)
                    } label: {
                        Text(reply.trimmed)
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                    }
                    .help(String(localized: "Senden: \(reply.trimmed)"))
                    .contextMenu {
                        Button("In Eingabe übernehmen", systemImage: "text.cursor") {
                            text = text.isEmpty ? reply.trimmed : text + " " + reply.trimmed
                            composerFocused = true
                        }
                        Button("Bearbeiten …", systemImage: "pencil") { editingQuickReplies = true }
                    }
                }
                Button {
                    editingQuickReplies = true
                } label: {
                    if quickReplies.usable.isEmpty {
                        Label("Schnellantworten", systemImage: "text.bubble")
                    } else {
                        Image(systemName: "text.bubble")
                    }
                }
                .help(String(localized: "Schnellantworten bearbeiten"))
                .accessibilityLabel("Schnellantworten bearbeiten")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = attachment.preview {
                                Image(decorative: preview, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            } else if let name = attachment.fileName {
                                VStack(spacing: 2) {
                                    Image(systemName: attachment.hostPath == nil ? "doc" : "doc.badge.arrow.up").font(.title3)
                                    Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(.quaternary)
                            } else {
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .accessibilityLabel(attachment.fileName == nil ? "Bild entfernen" : "Datei entfernen")
                    }
                }
            }
        }
    }

    /// Always tappable: a disabled button gives no feedback on iPad. With
    /// upload off it says how to turn it on.
    @ViewBuilder
    private var attachMenu: some View {
        if connection.config.uploadAllowed {
            Menu {
                Button("Fotos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                Button("Dateien …", systemImage: "folder") { importingFiles = true }
                Button("Aus Zwischenablage", systemImage: "doc.on.clipboard") {
                    Task { await addPasted(Platform.clipboardItems()) }
                }
            } label: {
                Image(systemName: "paperclip")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Bild oder Datei anhängen (auch per Drag & Drop)"))
        } else {
            Button {
                error = uploadOffMessage
            } label: {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Bilder hochladen ist für diesen Host aus"))
        }
    }

    private var uploadOffMessage: String {
        String(localized: "Bilder hochladen ist für \(connection.config.name) aus. Einschalten unter „…“ › „Bearbeiten …“ › „Bilder hochladen (SFTP)“.")
    }

    /// Reads images from the clipboard for the menu entry and ⌘V on the Mac.
    private func addPasted(_ items: [NSItemProvider]) async {
        let providers = items.filter { $0.registeredContentTypes.contains { $0.conforms(to: .image) } }
        guard !providers.isEmpty else {
            error = String(localized: "Die Zwischenablage enthält kein Bild.")
            return
        }
        var images: [ImageAttachment?] = []
        for provider in providers {
            images.append(await ImageAttachment.make(from: provider))
        }
        addPasted(images)
    }

    /// Pasted images join the attachments like picked photos, under the
    /// same per-host upload switch.
    private func addPasted(_ images: [ImageAttachment?]) {
        guard connection.config.uploadAllowed else {
            error = uploadOffMessage
            return
        }
        attachments.append(contentsOf: images.compactMap { $0 })
        if images.contains(where: { $0 == nil }) {
            error = String(localized: "Ein Bild aus der Zwischenablage konnte nicht gelesen werden.")
        }
    }

    #if os(macOS)
    /// The composer's text field takes ⌘V itself and drops images, so
    /// `onPasteCommand` never sees them while typing. This catches ⌘V first,
    /// but only when the composer is focused and the clipboard holds images
    /// and no text; every other ⌘V goes on to the text field unchanged.
    private func catchImagePaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard composerFocused, connection.isLive, !sending, Platform.clipboardHasImages else { return false }
                Task { await addPasted(Platform.clipboardItems()) }
                return true
            }
            return handled ? nil : event
        }
    }

    private func releaseImagePaste() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
    #endif

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let attachment = ImageAttachment.make(data: data, type: item.supportedContentTypes.first) {
                attachments.append(attachment)
            } else {
                error = String(localized: "Ein Bild konnte nicht gelesen werden.")
            }
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            add(Result { try ImageAttachment.content(fileAt: url) })
        }
    }

    /// A file's content: attached, or its text added to the prompt.
    private func add(_ result: Result<ImageAttachment.Content, Error>) {
        switch result {
        case .success(.attachment(let attachment)):
            attachments.append(attachment)
        case .success(.text(let clipped)):
            let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = current.isEmpty ? clipped : current + "\n" + clipped
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    /// Dropped files and images, under the same per-host upload switch as
    /// the paperclip.
    private func addDropped(_ providers: [NSItemProvider]) async {
        guard connection.config.uploadAllowed else {
            error = uploadOffMessage
            return
        }
        error = nil
        for provider in providers {
            do {
                add(.success(try await ImageAttachment.content(dropped: provider)))
            } catch {
                add(.failure(error))
            }
        }
    }

    private var answerRow: some View {
        // Side by side when there is room, label above the buttons on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                waitingLabel
                Spacer()
                answerButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                waitingLabel
                if question != nil {
                    // Option texts can be long; on a phone the row scrolls.
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) { answerButtons }
                    }
                    .scrollIndicators(.hidden)
                } else {
                    HStack(spacing: 6) { answerButtons }
                }
            }
        }
        .controlSize(.large)
    }

    private var waitingLabel: some View {
        Label("Wartet auf Antwort", systemImage: "hand.raised.fill")
            .foregroundStyle(AgentState.blocked.color)
            .font(.callout.weight(.medium))
    }

    @ViewBuilder
    private var answerButtons: some View {
        if let question {
            // Claude Code takes the digit as the answer, no Enter needed.
            ForEach(question.options, id: \.key) { option in
                Button { send(keys: [option.key]) } label: {
                    Text(option.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 240)
                }
                .help(option.label)
            }
        } else {
            ForEach(["1", "2", "3"], id: \.self) { key in
                Button(key) { send(keys: [key]) }
                    .help("Option \(key) wählen (⌥⌘\(key))")
            }
        }
        Button("Bestätigen", systemImage: "return") { send(keys: ["enter"]) }
            .buttonStyle(.borderedProminent)
            .tint(AgentState.blocked.color)
        Button("Abbrechen") { send(keys: ["esc"]) }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            keys
        }
    }

    private var keys: some View {
        HStack(spacing: 4) {
            if !verticalBar {
                dictationButton
                Divider().frame(height: 16)
            }
            key("Esc", "esc", help: "Esc (⌘.)")
            key("Tab", "tab")
            key("⌃C", "ctrl+c", help: "Control-C (⌃C)")
            Divider().frame(height: 16)
            key("↑", "up", help: "↑ (⌥⌘↑)")
            key("↓", "down", help: "↓ (⌥⌘↓)")
            key("←", "left", help: "← (⌥⌘←)")
            key("→", "right", help: "→ (⌥⌘→)")
            key("↩", "enter", help: "Enter (⇧⌘↩)")
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func key(_ label: String, _ name: String, help: String? = nil) -> some View {
        Button(label) { send(keys: [name]) }
            .help(help ?? label)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu
            if !history.prompts(for: historyKey).isEmpty {
                Button("Verlauf", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "Frühere Prompts dieser Pane"))
            }
            TextField(
                isAgent ? "Prompt an \(pane.agent ?? "Agent")" : "Befehl",
                text: $text,
                axis: .vertical
            )
            .lineLimit(1...8)
            .textFieldStyle(.roundedBorder)
            .focused($composerFocused)
            .onSubmit(submit)
            // Tab in an empty field goes to the pane, like the Tab key of the
            // key bar: Claude Code takes its suggested prompt, a shell
            // completes. With text, Tab keeps moving the focus.
            .onKeyPress(.tab) {
                if isLive {
                    // Claude completes in its own line; the composer starts
                    // over and keeps typing after the completion.
                    liveKey("tab")
                    liveTyped = ""
                    liveAfterTab = true
                    text = ""
                    return .handled
                }
                guard text.isEmpty, attachments.isEmpty else { return .ignored }
                send(keys: ["tab"])
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                arrow(press)
            }
            .onKeyPress(.escape) { liveArrow("esc") }
            .onChange(of: text) { syncLive() }
            // Another pane has its own input line: start live typing over.
            .onChange(of: pane.paneId) {
                liveTyped = ""
                liveAfterTab = false
            }
            // An approval dialog replaces the input line: start over after it.
            .onChange(of: isBlocked) { _, blocked in
                if blocked {
                    liveTyped = ""
                    liveAfterTab = false
                }
            }
            #if os(iOS)
            // The iPad keeps the button above the keyboard. On the iPhone
            // that toolbar is not counted by the keyboard avoidance and hid
            // the text field (#256); there the button sits in the row.
            .toolbar {
                if !isPhone {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Tastatur ausblenden", systemImage: "keyboard.chevron.compact.down") {
                            composerFocused = false
                        }
                    }
                }
            }
            #endif
            #if os(iOS)
            if isPhone && composerFocused && keyboardShown {
                Button("Tastatur ausblenden", systemImage: "keyboard.chevron.compact.down") {
                    composerFocused = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Tastatur ausblenden"))
            }
            #endif
            Button(isAgent ? "Senden" : "Ausführen", systemImage: "paperplane.fill", action: submit)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                #if !os(tvOS)
                .keyboardShortcut(.return, modifiers: .command)
                #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        #endif
    }

    /// Uploads attached images first, then sends the prompt with their paths
    /// appended; agents such as Claude Code read images from those paths.
    /// Starts and stops dictation into the composer; no keyboard needed.
    private var dictationButton: some View {
        Button {
            toggleDictation()
        } label: {
            Image(systemName: dictation.isRunning ? "mic.fill" : "mic")
                .foregroundStyle(dictation.isRunning ? Color.red : Color.accentColor)
                .symbolEffect(.pulse, isActive: dictation.isRunning)
        }
        .help(dictation.isRunning ? String(localized: "Diktat beenden") : String(localized: "Diktieren"))
        .accessibilityLabel(dictation.isRunning ? "Diktat beenden" : "Diktieren")
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        textBeforeDictation = text
        Task {
            await dictation.start()
            if let message = dictation.error { error = message }
        }
    }

    private func submit() {
        if dictation.isRunning { dictation.stop() }
        if isLive {
            liveKey("enter")
            liveTyped = ""
            liveAfterTab = false
            text = ""
            return
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Return in an empty field is Enter for the pane, e.g. to send a
        // suggestion taken with Tab.
        guard !prompt.isEmpty || !attachments.isEmpty else {
            text = ""
            send(keys: ["enter"])
            return
        }
        let pending = attachments
        perform {
            let paths = pending.isEmpty ? [] : try await connection.upload(pending)
            // In a shell the paths become arguments: quote them, so no file
            // name can add a command (the core already keeps names plain).
            let shown = isAgent ? paths : paths.map(Self.shellQuoted)
            let full = ([prompt] + shown).filter { !$0.isEmpty }.joined(separator: isAgent ? "\n" : " ")
            try await connection.submit(full, to: pane.paneId, isAgent: isAgent)
            if isAgent {
                // Agents only: a shell may have asked for a password.
                history.record(prompt, for: historyKey)
                if let item = connection.update?.board.first(where: { $0.paneId == pane.paneId }) {
                    LastAgent.remember(item, on: connection.id)
                }
            }
            text = ""
            attachments.removeAll { item in pending.contains { $0.id == item.id } }
        }
    }

    /// `'path'`, with embedded `'` written as `'\''`.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sends a quick reply as is; composer text and attachments stay.
    private func send(quickReply: String) {
        perform { try await connection.submit(quickReply, to: pane.paneId, isAgent: isAgent) }
    }

    private func send(keys: [String]) {
        perform { try await connection.send(keys: keys, to: pane.paneId) }
    }

    /// Runs a send; the composer gets its focus back only if it had it, so
    /// a tap on the key bar does not bring up the keyboard on iOS.
    /// Brings the agent's input line to the composer text in live mode.
    /// Newlines become spaces: in Claude Code a newline would submit.
    private func syncLive() {
        guard isAgent, !isBlocked, attachments.isEmpty else { return }
        let target = liveAfterTab || text.hasPrefix("/") ? text.replacingOccurrences(of: "\n", with: " ") : ""
        let edit = LiveEdit(from: liveTyped, to: target)
        guard !edit.isEmpty else { return }
        liveTyped = target
        let paneID = pane.paneId
        enqueueLive { connection in
            if edit.erase > 0 {
                try await connection.send(keys: Array(repeating: "backspace", count: edit.erase), to: paneID)
            }
            if !edit.insert.isEmpty {
                try await connection.send(text: edit.insert, to: paneID)
            }
        }
    }

    private func liveKey(_ key: String) {
        let paneID = pane.paneId
        enqueueLive { try await $0.send(keys: [key], to: paneID) }
    }

    /// Arrow keys and Esc go to the agent in live mode, to pick from or
    /// close its suggestions.
    private func liveArrow(_ key: String) -> KeyPress.Result {
        guard isLive else { return .ignored }
        liveKey(key)
        return .handled
    }

    /// Plain arrow keys in an empty composer go to the pane, to move through
    /// an agent's question or a shell's history; with text they move the
    /// cursor. In live mode up and down pick from the agent's suggestions.
    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, let key = Self.arrowKeys[press.key] else { return .ignored }
        if isLive { return key == "up" || key == "down" ? liveArrow(key) : .ignored }
        guard text.isEmpty, attachments.isEmpty else { return .ignored }
        liveKey(key)
        return .handled
    }

    private static let arrowKeys: [KeyEquivalent: String] = [
        .upArrow: "up", .downArrow: "down", .leftArrow: "left", .rightArrow: "right",
    ]

    private func enqueueLive(_ step: @escaping @MainActor (HostConnection) async throws -> Void) {
        let previous = liveQueue
        let connection = connection
        error = nil
        liveQueue = Task { @MainActor in
            await previous?.value
            do {
                try await step(connection)
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        let refocus = composerFocused
        sending = true
        error = nil
        Task {
            defer {
                sending = false
                if refocus { composerFocused = true }
            }
            do {
                try await action()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}

/// What the composer of the shown pane holds, for the input bar that takes
/// over when the layout changes.
@MainActor
private enum ComposerDraft {
    static var slot: (key: String, text: String, attachments: [ImageAttachment])?
}

/// Files on the host the file browser sends to a pane's composer (#271),
/// per host and pane like `ComposerDraft`, until its input bar takes them.
@MainActor
enum ComposerInbox {
    static let arrived = Notification.Name("ComposerInbox.arrived")
    private static var paths: [String: [String]] = [:]

    static func add(path: String, hostID: UUID, paneID: String) {
        paths[key(hostID: hostID, paneID: paneID), default: []].append(path)
        NotificationCenter.default.post(name: arrived, object: nil)
    }

    static func take(key: String) -> [String] {
        paths.removeValue(forKey: key) ?? []
    }

    /// The same as `InputBar.draftKey`.
    static func key(hostID: UUID, paneID: String) -> String { "\(hostID)/\(paneID)" }
}

/// Starts dictation a control asked for (#227) when the request or the app
/// lock changes; its own modifier, so the input bar's chain stays short
/// enough for the type checker.
private struct RequestedDictation: ViewModifier {
    let request: DictateRequest?
    let covered: Bool
    let start: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: request, initial: true) { start() }
            .onChange(of: covered) { start() }
    }
}
