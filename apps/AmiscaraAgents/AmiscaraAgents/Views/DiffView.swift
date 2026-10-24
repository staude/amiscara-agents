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
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var query = ""
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
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }

    private var summary: String {
        let added = files.reduce(0) { $0 + Int($1.additions) }
        let removed = files.reduce(0) { $0 + Int($1.deletions) }
        return String(localized: "\(files.count) Dateien, +\(added) −\(removed)")
    }

    private func load() async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        do {
            files = try await connection.workingTreeDiff(paneID: paneID)
            error = nil
            // A single file opens right away.
            if files.count == 1 { open = [files[0].path] }
        } catch {
            self.error = inputErrorMessage(error)
        }
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
        if file.status == .binary {
            Text("Binärdatei").font(.caption).foregroundStyle(.secondary)
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
        case .binary: "B"
        }
    }

    var label: String {
        switch self {
        case .modified: String(localized: "geändert")
        case .added: String(localized: "neu")
        case .deleted: String(localized: "gelöscht")
        case .renamed: String(localized: "umbenannt")
        case .untracked: String(localized: "nicht in Git")
        case .binary: String(localized: "binär")
        }
    }

    var color: Color {
        switch self {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified, .binary: .orange
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
