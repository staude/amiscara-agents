import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)

/// The files on the host, starting in a pane's working directory (#259);
/// the home directory is the root. Over SSH it needs the same SFTP access
/// as uploads. With input allowed a file can go to the pane's composer and
/// small text files can be edited (#271).
struct FileBrowserView: View {
    let connection: HostConnection
    let paneID: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fileBrowserShowsHidden") private var showsHidden = false
    @State private var directory: Directory?
    @State private var loading = false
    @State private var error: String?
    /// Counts loads; only the latest one's answer is shown.
    @State private var generation = 0
    /// The last error came from the host's files, not from the connection.
    @State private var filesError = false

    private var shown: [DirectoryEntry] {
        guard let directory else { return [] }
        return showsHidden ? directory.entries : directory.entries.filter { !$0.hidden }
    }

    private var atHome: Bool {
        directory.map { $0.path == $0.home } ?? true
    }

    /// A host on "read only" stays so for its files too.
    private var canAct: Bool { connection.config.inputAllowed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(for: String.self) { path in
                    FilePreviewView(connection: connection, path: path, canAct: canAct, send: send)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .navigation) {
                        Button("Übergeordneter Ordner", systemImage: "chevron.backward") {
                            guard let directory else { return }
                            open((directory.path as NSString).deletingLastPathComponent)
                        }
                        .disabled(atHome || loading)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Toggle("Versteckte zeigen", systemImage: "eye", isOn: $showsHidden)
                        Button("Neu laden", systemImage: "arrow.clockwise") {
                            if let directory {
                                open(directory.path)
                            } else {
                                Task { await load { try await connection.openPaneDirectory(paneID: paneID) } }
                            }
                        }
                        .disabled(loading)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 680)
        #endif
        .task { await load { try await connection.openPaneDirectory(paneID: paneID) } }
    }

    private var title: String {
        guard let directory else { return String(localized: "Dateien") }
        return atHome ? "~" : (directory.path as NSString).lastPathComponent
    }

    @ViewBuilder
    private var content: some View {
        if let directory {
            List {
                Section {
                    ForEach(shown, id: \.path) { entry in
                        row(entry)
                    }
                } header: {
                    PathBar(directory: directory, open: open)
                        .disabled(loading)
                } footer: {
                    footer(directory)
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        } else if let error {
            ContentUnavailableView {
                Label("Dateien nicht lesbar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                // E.g. the pane's directory was removed.
                if filesError {
                    Button("Home-Verzeichnis öffnen") { open("") }
                        .disabled(loading)
                }
            }
        } else {
            ProgressView("Ordner wird gelesen …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ entry: DirectoryEntry) -> some View {
        switch entry.kind {
        case .directory:
            Button {
                open(entry.path)
            } label: {
                EntryRow(entry: entry)
            }
            .tint(.primary)
            .disabled(loading)
        case .file:
            NavigationLink(value: entry.path) {
                EntryRow(entry: entry)
            }
            .contextMenu {
                if canAct, ImageAttachment.isPlainPath(entry.path) {
                    Button("An Agent senden", systemImage: "paperplane") { send(entry.path) }
                }
            }
        case .other:
            EntryRow(entry: entry)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func footer(_ directory: Directory) -> some View {
        let hidden = directory.entries.count - shown.count
        if directory.entries.isEmpty {
            Text("Der Ordner ist leer.")
        } else if hidden > 0 {
            Text("\(hidden) versteckte Einträge")
        }
        // A failed change of folder keeps the last list; say why.
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    /// Attaches the file to the pane's composer and closes the browser,
    /// which covers the composer on the iPhone.
    private func send(_ path: String) {
        ComposerInbox.add(path: path, hostID: connection.id, paneID: paneID)
        dismiss()
    }

    private func open(_ path: String) {
        Task { await load { try await connection.listDirectory(path) } }
    }

    private func load(_ fetch: @escaping () async throws -> Directory) async {
        generation += 1
        let current = generation
        loading = true
        do {
            let next = try await fetch()
            guard current == generation else { return }
            directory = next
            error = nil
        } catch {
            guard current == generation else { return }
            self.error = inputErrorMessage(error)
            if case FfiError.Files = error { filesError = true } else { filesError = false }
        }
        loading = false
    }
}

/// "~" and each folder below it up to the current one; tapping one opens it.
private struct PathBar: View {
    let directory: Directory
    let open: (String) -> Void

    private var parts: [(name: String, path: String)] {
        let rest = directory.path.dropFirst(directory.home.count)
        // No double slash below a home of `/`.
        var path = directory.home == "/" ? "" : directory.home
        return rest.split(separator: "/").map { name in
            path += "/" + name
            return (String(name), path)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("~") { open(directory.home) }
                    .disabled(directory.path == directory.home)
                ForEach(parts, id: \.path) { part in
                    Image(systemName: "chevron.forward")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Button(part.name) { open(part.path) }
                        .disabled(part.path == directory.path)
                }
            }
            .font(.callout.monospaced())
            .buttonStyle(.borderless)
            .textCase(nil)
        }
        .defaultScrollAnchor(.trailing)
    }
}

private struct EntryRow: View {
    let entry: DirectoryEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(entry.name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if entry.kind == .file {
                    Text(fileSize(entry.size))
                }
                if entry.modified > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(entry.modified)).formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if entry.kind == .directory {
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .directory: "folder"
        case .file: "doc"
        case .other: "questionmark.square.dashed"
        }
    }
}

/// One file: text with search, an image, or only size and type. With
/// `canAct` it can go to the composer, and a small text file can be edited
/// and saved (#271).
private struct FilePreviewView: View {
    let connection: HostConnection
    let path: String
    let canAct: Bool
    let send: (String) -> Void
    @State private var preview: FilePreview?
    @State private var error: String?
    @State private var findRequest = 0
    /// The text being edited; `nil` while viewing.
    @State private var draft: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var conflict = false
    @State private var confirmingDiscard = false

    private var originalText: String? {
        if case .text(let text, _) = preview?.content { text } else { nil }
    }

    private var changed: Bool { draft != nil && draft != originalText }

    var body: some View {
        content
            .navigationTitle((path as NSString).lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationBarBackButtonHidden(draft != nil)
            .interactiveDismissDisabled(changed)
            .toolbar {
                if draft != nil {
                    editToolbar
                } else {
                    viewToolbar
                }
            }
            .confirmationDialog("Änderungen verwerfen?", isPresented: $confirmingDiscard) {
                Button("Verwerfen", role: .destructive) { stopEditing() }
            }
            .alert("Datei auf dem Host geändert", isPresented: $conflict) {
                Button("Neu laden", role: .destructive) {
                    stopEditing()
                    // The viewer reads its text once; show the loading state.
                    preview = nil
                    Task { await load() }
                }
                Button("Weiter bearbeiten", role: .cancel) {}
            } message: {
                Text("Seit dem Öffnen hat sich die Datei auf dem Host geändert. „Neu laden“ verwirft die Änderungen in der App; wer sie behalten will, kopiert sie vorher.")
            }
            .task { await load() }
    }

    @ToolbarContentBuilder
    private var viewToolbar: some ToolbarContent {
        if case .text = preview?.content {
            ToolbarItem(placement: .primaryAction) {
                Button("Suchen", systemImage: "magnifyingglass") { findRequest += 1 }
            }
        }
        if canAct {
            if ImageAttachment.isPlainPath(preview?.path ?? path) {
                ToolbarItem(placement: .primaryAction) {
                    Button("An Agent senden", systemImage: "paperplane") { send(preview?.path ?? path) }
                }
            }
            if let preview, preview.editable, let originalText {
                ToolbarItem(placement: .primaryAction) {
                    Button("Bearbeiten", systemImage: "pencil") {
                        saveError = nil
                        draft = originalText
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Abbrechen") {
                if changed { confirmingDiscard = true } else { stopEditing() }
            }
            .disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Sichern", action: save)
                .keyboardShortcut("s")
                .disabled(!changed || saving)
        }
    }

    private func load() async {
        error = nil
        do {
            preview = try await connection.filePreview(path)
        } catch {
            preview = nil
            self.error = inputErrorMessage(error)
        }
    }

    private func stopEditing() {
        draft = nil
        saveError = nil
    }

    /// Writes the draft unless the file changed on the host meanwhile; then
    /// the draft stays and the alert offers to reload. Text typed while
    /// saving keeps the editor open, on the saved file as the new base.
    private func save() {
        guard let preview, let draft else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do {
                self.preview = try await connection.saveFile(preview, text: draft)
                if self.draft == draft { stopEditing() }
            } catch FfiError.FileChanged {
                conflict = true
            } catch {
                saveError = inputErrorMessage(error)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if preview != nil, draft != nil {
            VStack(spacing: 0) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }
                EditableTextView(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .disabled(saving)
            }
        } else if let preview {
            switch preview.content {
            case .text(let text, let truncated):
                VStack(spacing: 0) {
                    if truncated {
                        Label("Nur das erste MB wird gezeigt.", systemImage: "scissors")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                    }
                    NativeTextView(text: text, scrollsToEnd: false, findRequest: findRequest)
                }
            case .image(let data):
                if let image = Image(fileData: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    binary(preview)
                }
            case .binary:
                binary(preview)
            }
        } else if let error {
            ContentUnavailableView("Datei nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Datei wird geladen …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func binary(_ preview: FilePreview) -> some View {
        let ext = (preview.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext)?.localizedDescription ?? String(localized: "Datei")
        return ContentUnavailableView {
            Label(preview.name, systemImage: "doc")
        } description: {
            Text("\(type), \(fileSize(preview.size))")
        }
    }
}

private func fileSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

#endif
