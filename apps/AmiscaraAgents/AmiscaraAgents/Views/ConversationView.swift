import SwiftUI

/// The conversation of a Claude Code pane, read from its session file on the
/// host: herdr keeps no scrollback for full-screen programs (#102). Newest
/// at the bottom, older parts load on request. From a search hit (#303) it
/// opens at the hit's entry, marked, and newer parts load too. Read only.
struct ConversationView: View {
    /// What to show: the newest part of a pane's conversation, or the part
    /// around a search hit's line in a session file.
    enum Source: Equatable {
        case pane(String)
        case match(sessionPath: String, offset: UInt64)
    }

    let connection: HostConnection
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    /// Where older entries continue; `nil` at the session's start.
    @State private var older: TranscriptCursor?
    /// Where newer entries continue from a hit; `nil` at the session's end.
    @State private var newer: TranscriptCursor?
    /// The entry of the hit, marked and scrolled to.
    @State private var highlightID: Int?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    init(connection: HostConnection, source: Source) {
        self.connection = connection
        self.source = source
    }

    init(connection: HostConnection, paneID: String) {
        self.init(connection: connection, source: .pane(paneID))
    }

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
                        SelectTextButton(title: String(localized: "Gesprächsverlauf")) { transcript }
                            .disabled(items.isEmpty)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        olderRow
                        ForEach(items) { item in
                            EntryRow(entry: item.entry, highlighted: item.id == highlightID)
                                .id(item.id)
                        }
                        if case .match = source {
                            newerRow
                        }
                    }
                    .padding()
                    .selectableText()
                }
                .defaultScrollAnchor(isMatch ? .top : .bottom)
                .onAppear { scroll(proxy) }
                .onChange(of: highlightID) { scroll(proxy) }
            }
        }
    }

    private var isMatch: Bool {
        if case .match = source { true } else { false }
    }

    /// To the hit's entry, once the list has laid it out.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlightID else { return }
        Task { @MainActor in
            proxy.scrollTo(highlightID, anchor: .center)
        }
    }

    /// The loaded entries as plain text: prompts after `>`, tool calls
    /// after `·`, blank lines between entries.
    private var transcript: String {
        items.map { item in
            switch item.entry.kind {
            case .user: "> " + item.entry.text
            case .assistant: item.entry.text
            case .tool: "· " + item.entry.text
            }
        }
        .joined(separator: "\n\n")
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

    private var newerRow: some View {
        HStack {
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else if newer != nil {
                Button("Neuere Einträge laden", systemImage: "arrow.down") {
                    Task { await loadNewer() }
                }
                .buttonStyle(.bordered)
            } else {
                Text("Ende der Sitzung").foregroundStyle(.secondary)
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
            if reset, case .match(let path, let offset) = source {
                let span = try await connection.claudeHistory(at: path, offset: offset)
                items = span.entries.enumerated().map { Item(id: $0.offset, entry: $0.element) }
                older = span.start > 0 ? TranscriptCursor(sessionPath: span.sessionPath, start: span.start) : nil
                newer = span.atEnd ? nil : TranscriptCursor(sessionPath: span.sessionPath, start: span.end)
                highlightID = span.highlight.map(Int.init)
                error = nil
                loaded = true
                return
            }
            let page: TranscriptPage
            switch source {
            case .pane(let paneID):
                page = try await connection.claudeHistory(paneID: paneID, before: reset ? nil : older)
            case .match:
                guard let older else { return }
                page = try await connection.claudeHistory(before: older)
            }
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

    /// The entries after the last one shown, from a hit.
    private func loadNewer() async {
        guard !loading, let newer else { return }
        loading = true
        defer { loading = false }
        do {
            let span = try await connection.claudeHistory(after: newer.sessionPath, from: newer.start)
            let nextID = (items.last?.id ?? -1) + 1
            items += span.entries.enumerated().map { Item(id: nextID + $0.offset, entry: $0.element) }
            self.newer = span.atEnd ? nil : TranscriptCursor(sessionPath: span.sessionPath, start: span.end)
            error = nil
        } catch {
            self.error = inputErrorMessage(error)
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry
    var highlighted = false

    var body: some View {
        content
            .padding(highlighted ? 6 : 0)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.22))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
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
        guard let date = claudeDate(entry.timestamp) else { return nil }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}
