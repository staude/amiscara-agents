import SwiftUI

#if !os(tvOS)

/// What an agent changed in its working directory (#228): `git diff`
/// against `HEAD` plus untracked files, per file with its hunks. Read only;
/// the host runs Git in a short-lived tab of the pane's space.
struct DiffView: View {
    let connection: HostConnection
    let paneID: String
    @Environment(\.dismiss) private var dismiss
    @State private var files: [DiffFile] = []
    @State private var truncated = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Änderungen")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(tvOS)
                .searchable(text: $query, prompt: "Dateien und Zeilen durchsuchen")
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Neu laden", systemImage: "arrow.clockwise") {
                            Task { await load() }
                        }
                        .disabled(loading)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 680)
        #endif
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error, files.isEmpty {
            ContentUnavailableView("Änderungen nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !loaded {
            ProgressView("Git wird gefragt …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            ContentUnavailableView("Keine Änderungen", systemImage: "checkmark.circle", description: Text("Das Arbeitsverzeichnis entspricht dem letzten Commit."))
        } else {
            List {
                // A failed reload keeps the last list; say it is old.
                DiffFileList(files: files, truncated: truncated, query: query, note: error)
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }

    private func load() async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        do {
            let diff = try await connection.workingTreeDiff(paneID: paneID)
            files = diff.files
            truncated = diff.truncated
            error = nil
        } catch {
            self.error = inputErrorMessage(error)
        }
    }
}

/// The files of a diff as a list section, each folding out to its hunks;
/// also the diff of a pull request (#309). `query` filters by path and
/// line, `note` shows under the files, e.g. a failed reload.
struct DiffFileList: View {
    let files: [DiffFile]
    let truncated: Bool
    var query = ""
    var note: String?
    @State private var open: Set<String> = []

    private var shown: [DiffFile] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { file in
            file.path.localizedStandardContains(query)
                || file.hunks.contains { $0.lines.contains { $0.text.localizedStandardContains(query) } }
        }
    }

    var body: some View {
        Section {
            ForEach(shown, id: \.path) { file in
                DisclosureGroup(isExpanded: Binding(
                    get: { open.contains(file.path) },
                    set: { if $0 { open.insert(file.path) } else { open.remove(file.path) } }
                )) {
                    FileHunks(file: file)
                } label: {
                    FileRow(file: file)
                }
            }
        } header: {
            Text(summary)
        } footer: {
            if truncated {
                Label("Die Änderungen sind zu groß und wurden abgeschnitten; es fehlen Dateien.", systemImage: "scissors")
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        // A single file opens right away.
        .onChange(of: files.map(\.path), initial: true) { _, paths in
            if paths.count == 1 { open = Set(paths) }
        }
    }

    private var summary: String {
        let added = files.reduce(0) { $0 + Int($1.additions) }
        let removed = files.reduce(0) { $0 + Int($1.deletions) }
        return String(localized: "\(files.count) Dateien, +\(added) −\(removed)")
    }
}

private struct FileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.badge)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(file.status.color)
                .frame(width: 16)
                .accessibilityLabel(file.status.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.head)
                if let old = file.oldPath {
                    Text("aus \(old)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.additions > 0 {
                Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
        }
    }
}

private struct FileHunks: View {
    let file: DiffFile

    var body: some View {
        if file.binary {
            Text("Binärdatei").font(.caption).foregroundStyle(.secondary)
        } else if file.tooLarge {
            Text("Zu groß zum Anzeigen").font(.caption).foregroundStyle(.secondary)
        } else if file.hunks.isEmpty {
            Text("Keine Zeilen geändert").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        Text(hunk.header)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.prefix + line.text)
                                .foregroundStyle(line.kind.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind.background)
                        }
                    }
                }
                .font(.caption.monospaced())
                .selectableText()
            }
        }
    }
}

extension DiffFileStatus {
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        }
    }

    var label: String {
        switch self {
        case .modified: String(localized: "geändert")
        case .added: String(localized: "neu")
        case .deleted: String(localized: "gelöscht")
        case .renamed: String(localized: "umbenannt")
        case .untracked: String(localized: "nicht in Git")
        }
    }

    var color: Color {
        switch self {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .orange
        }
    }
}

extension DiffLine {
    var prefix: String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        case .note: ""
        }
    }
}

extension DiffLineKind {
    var color: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .context: .primary
        case .note: .secondary
        }
    }

    var background: Color {
        switch self {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .context, .note: .clear
        }
    }
}
#endif
