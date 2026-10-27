import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)

/// The files on the host, starting in a pane's working directory (#259).
/// Read only; the home directory is the root. Over SSH it needs the same
/// SFTP access as uploads.
struct FileBrowserView: View {
    let connection: HostConnection
    let paneID: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fileBrowserShowsHidden") private var showsHidden = false
    @State private var directory: Directory?
    @State private var loading = false
    @State private var error: String?

    private var shown: [DirectoryEntry] {
        guard let directory else { return [] }
        return showsHidden ? directory.entries : directory.entries.filter { !$0.hidden }
    }

    private var atHome: Bool {
        directory.map { $0.path == $0.home } ?? true
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(for: String.self) { path in
                    FilePreviewView(connection: connection, path: path)
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
                } footer: {
                    footer(directory)
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        } else if let error {
            ContentUnavailableView("Dateien nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
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

    private func open(_ path: String) {
        Task { await load { try await connection.listDirectory(path) } }
    }

    private func load(_ fetch: @escaping () async throws -> Directory) async {
        loading = true
        defer { loading = false }
        do {
            directory = try await fetch()
            error = nil
        } catch {
            self.error = inputErrorMessage(error)
        }
    }
}

/// "~" and each folder below it up to the current one; tapping one opens it.
private struct PathBar: View {
    let directory: Directory
    let open: (String) -> Void

    private var parts: [(name: String, path: String)] {
        let rest = directory.path.dropFirst(directory.home.count)
        var path = directory.home
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

/// One file: text with search, an image, or only size and type.
private struct FilePreviewView: View {
    let connection: HostConnection
    let path: String
    @State private var preview: FilePreview?
    @State private var error: String?
    @State private var findRequest = 0

    var body: some View {
        content
            .navigationTitle((path as NSString).lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if case .text = preview?.content {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Suchen", systemImage: "magnifyingglass") { findRequest += 1 }
                    }
                }
            }
            .task {
                do {
                    preview = try await connection.filePreview(path)
                } catch {
                    self.error = inputErrorMessage(error)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
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
