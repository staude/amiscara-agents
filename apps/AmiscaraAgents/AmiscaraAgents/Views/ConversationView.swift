import SwiftUI

/// The conversation of a Claude Code pane, read from its session file on the
/// host: herdr keeps no scrollback for full-screen programs (#102). Newest
/// at the bottom, older parts load on request. Read only.
struct ConversationView: View {
    let connection: HostConnection
    let paneID: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    /// Where older entries continue; `nil` at the session's start.
    @State private var older: TranscriptCursor?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    /// Ids count down for older entries, so loading more keeps the ids (and
    /// the scroll position) of the entries already shown.
    private struct Item: Identifiable {
        let id: Int
        let entry: TranscriptEntry
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Gesprächsverlauf")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Neu laden", systemImage: "arrow.clockwise") {
                            Task { await load(reset: true) }
                        }
                        .disabled(loading)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 680)
        #endif
        .task { await load(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        if let error, items.isEmpty {
            ContentUnavailableView("Verlauf nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !loaded {
            ProgressView("Sitzung wird gesucht …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView("Noch keine Einträge", systemImage: "text.bubble")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    olderRow
                    ForEach(items) { item in
                        EntryRow(entry: item.entry)
                    }
                }
                .padding()
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private var olderRow: some View {
        HStack {
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else if older != nil {
                Button("Ältere Einträge laden", systemImage: "arrow.up") {
                    Task { await load(reset: false) }
                }
                .buttonStyle(.bordered)
            } else {
                Text("Anfang der Sitzung").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await connection.claudeHistory(paneID: paneID, before: reset ? nil : older)
            let firstID = reset ? 0 : (items.first?.id ?? 0)
            let added = page.entries.enumerated().map { offset, entry in
                Item(id: firstID - page.entries.count + offset, entry: entry)
            }
            items = reset ? added : added + items
            older = page.start > 0 ? TranscriptCursor(sessionPath: page.sessionPath, start: page.start) : nil
            error = nil
        } catch {
            self.error = inputErrorMessage(error)
        }
        loaded = true
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                if let time {
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            Text(markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// Claude writes Markdown; inline styles and links, line breaks kept.
    private var markdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: entry.text, options: options)) ?? AttributedString(entry.text)
    }

    private var time: String? {
        // Claude Code writes milliseconds, e.g. 2026-10-18T10:12:33.123Z.
        guard let stamp = entry.timestamp,
              let date = (try? Date(stamp, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
                ?? (try? Date(stamp, strategy: .iso8601))
        else { return nil }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}
