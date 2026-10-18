import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Input under the pane screen: one-tap answers while an agent waits, a key
/// bar, and a composer. Answers appear only here, next to the screen they
/// answer, never blind from the board.
struct InputBar: View {
    let connection: HostConnection
    let pane: PaneItem

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var attachments: [ImageAttachment] = []
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var choosingPhotos = false
    @FocusState private var composerFocused: Bool
    @State private var dictation = Dictation()
    /// Composer text from before dictation started; the transcript follows it.
    @State private var textBeforeDictation = ""
    @State private var editingQuickReplies = false
    private let quickReplies = QuickReplyStore.shared
    #if os(macOS)
    /// Key monitor for ⌘V in the composer, see `catchImagePaste`.
    @State private var pasteMonitor: Any?
    #endif

    private var isAgent: Bool { pane.agent != nil }
    private var isBlocked: Bool { isAgent && pane.agentState == .blocked }

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
            composer
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .disabled(sending || !connection.isLive)
        .onChange(of: dictation.error) { _, message in
            if let message { error = message }
        }
        .onChange(of: dictation.transcript) { _, spoken in
            guard dictation.isRunning || !spoken.isEmpty else { return }
            let base = textBeforeDictation.trimmingCharacters(in: .whitespaces)
            text = base.isEmpty ? spoken : base + " " + spoken
        }
        .onDisappear { dictation.stop() }
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
        .onChange(of: pane.paneId) {
            dictation.stop()
            text = ""
            error = nil
            attachments = []
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        // Presented from the view, not as a PhotosPicker inside the Menu,
        // which often does not open on iOS.
        .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, maxSelectionCount: 5, matching: .images)
        .sheet(isPresented: $editingQuickReplies) {
            QuickReplyEditor(store: quickReplies)
        }
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
                        .accessibilityLabel("Bild entfernen")
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
            .help(String(localized: "Bild anhängen"))
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
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let attachment = ImageAttachment.make(data: data, type: UTType(filenameExtension: url.pathExtension))
            else {
                error = String(localized: "\(url.lastPathComponent) ist kein lesbares Bild.")
                continue
            }
            attachments.append(attachment)
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
                HStack(spacing: 6) { answerButtons }
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
        ForEach(["1", "2", "3"], id: \.self) { key in
            Button(key) { send(keys: [key]) }
                .help("Option \(key) wählen")
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
            dictationButton
            Divider().frame(height: 16)
            key("Esc", "esc")
            key("Tab", "tab")
            key("⌃C", "ctrl+c", help: "Control-C")
            Divider().frame(height: 16)
            key("↑", "up")
            key("↓", "down")
            key("←", "left")
            key("→", "right")
            key("↩", "enter", help: "Enter")
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
            TextField(
                isAgent ? "Prompt an \(pane.agent ?? "Agent")" : "Befehl",
                text: $text,
                axis: .vertical
            )
            .lineLimit(1...8)
            .textFieldStyle(.roundedBorder)
            .focused($composerFocused)
            .onSubmit(submit)
            Button(isAgent ? "Senden" : "Ausführen", systemImage: "paperplane.fill", action: submit)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
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
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        let pending = attachments
        perform {
            let paths = pending.isEmpty ? [] : try await connection.upload(pending)
            let full = ([prompt] + paths).filter { !$0.isEmpty }.joined(separator: isAgent ? "\n" : " ")
            try await connection.submit(full, to: pane.paneId, isAgent: isAgent)
            text = ""
            attachments.removeAll { item in pending.contains { $0.id == item.id } }
        }
    }

    /// Sends a quick reply as is; composer text and attachments stay.
    private func send(quickReply: String) {
        perform { try await connection.submit(quickReply, to: pane.paneId, isAgent: isAgent) }
    }

    private func send(keys: [String]) {
        perform { try await connection.send(keys: keys, to: pane.paneId) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        sending = true
        error = nil
        Task {
            defer {
                sending = false
                composerFocused = true
            }
            do {
                try await action()
            } catch {
                self.error = inputErrorMessage(error)
            }
        }
    }
}
