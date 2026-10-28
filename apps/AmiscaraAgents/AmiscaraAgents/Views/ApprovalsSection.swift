#if !os(tvOS)
import SwiftUI

/// "Freigaben" (#296): issues of the hosts' repositories whose plan waits
/// for approval, for one host or all. Hidden without entries and errors.
/// A tap shows the plan's overview with the answers for its planning tab.
struct ApprovalsSection: View {
    @Environment(HostStore.self) private var store
    /// One host, or all with `nil`.
    let hostID: UUID?
    let select: (Approvals.Item) -> Void

    var body: some View {
        let approvals = store.approvals
        let items = approvals.items(for: hostID, in: store.connections)
        let errors = approvals.errors(for: hostID, in: store.connections)
        if !items.isEmpty || !errors.isEmpty {
            Section {
                ForEach(items) { item in
                    Button {
                        select(item)
                    } label: {
                        ApprovalRow(item: item, hostName: hostID == nil ? store.connection(for: item.hostID)?.config.name : nil)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(errors, id: \.host) { error in
                    Label {
                        Text(hostID == nil ? "\(error.host): \(error.message)" : error.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .selectableText()
                }
            } header: {
                HStack {
                    Text("Freigaben")
                    Spacer()
                    if approvals.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await approvals.load(store.connections, force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Aktualisieren")
                        .accessibilityLabel("Aktualisieren")
                    }
                }
            }
        }
    }
}

private struct ApprovalRow: View {
    @Environment(HostStore.self) private var store
    let item: Approvals.Item
    let hostName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.purple)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "#\(item.number) \(item.title)")
                    .lineLimit(2)
                Text([item.repo, hostName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                status
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if let approved = store.approvals.answered[item.id] {
            Label(approved ? "Freigegeben" : "Später", systemImage: approved ? "checkmark.circle" : "clock")
                .foregroundStyle(approved ? .green : .secondary)
        } else if Approvals.planTab(for: item, in: store.connection(for: item.hostID)) != nil {
            Label("Planungs-Tab wartet", systemImage: "hand.raised")
                .foregroundStyle(.orange)
        } else if item.overview == nil {
            Text("Kein Plan gefunden")
                .foregroundStyle(.secondary)
        }
    }
}

/// One plan waiting for approval: its overview, the answers for the
/// planning tab and the link to the issue.
struct ApprovalDetail: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Approvals.Item
    let open: (SpaceRef) -> Void
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?
    /// Whether the tab asks the approval question; `nil` until read.
    @State private var asksApproval: Bool?
    @State private var copied = false

    var body: some View {
        let connection = store.connection(for: item.hostID)
        let tab = Approvals.planTab(for: item, in: connection)
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: item.title)
                        .font(.headline)
                    Text([item.repo, connection?.config.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Überblick für die Freigabe") {
                    if let overview = item.overview {
                        Text(Self.rendered(overview))
                            .selectableText()
                    } else {
                        Text("Kein Plan gefunden")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    answers(connection: connection, tab: tab)
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .selectableText()
                    }
                }
                if let url = item.url {
                    Section {
                        Link(destination: url) {
                            Label("Issue auf GitHub öffnen", systemImage: "safari")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: "#\(item.number)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .task(id: tab?.paneId) {
            asksApproval = nil
            guard let tab, let connection else { return }
            asksApproval = await Approvals.approvalQuestion(in: tab, on: connection) != nil
        }
    }

    @ViewBuilder
    private func answers(connection: HostConnection?, tab: BoardItem?) -> some View {
        if let approved = store.approvals.answered[item.id] {
            Label(
                approved ? "Freigegeben. Der Planungs-Tab startet die Umsetzung." : "Später. Der Plan wartet weiter auf Freigabe.",
                systemImage: approved ? "checkmark.circle" : "clock"
            )
            .foregroundStyle(approved ? .green : .secondary)
        } else if let connection, let tab {
            if !connection.config.inputAllowed {
                Text("Eingaben sind für diesen Host ausgeschaltet. Im Planungs-Tab freigeben.")
                    .foregroundStyle(.secondary)
            } else if asksApproval == nil {
                ProgressView()
            } else if asksApproval == false {
                Text("Der Planungs-Tab stellt gerade eine andere Frage, z. B. offene Fragen des Plans. Erst dort beantworten.")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    send(.approve, on: connection)
                } label: {
                    Label("Freigeben", systemImage: "checkmark.seal")
                }
                .disabled(sending)
                Button {
                    send(.later, on: connection)
                } label: {
                    Label("Später", systemImage: "clock")
                }
                .disabled(sending)
                TextField("Hinweis zur Umsetzung", text: $note, axis: .vertical)
                Button {
                    send(.note(note), on: connection)
                } label: {
                    Label("Mit Hinweis freigeben", systemImage: "text.bubble")
                }
                .disabled(sending || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button {
                dismiss()
                open(SpaceRef(hostID: item.hostID, workspaceID: tab.workspaceId, paneID: tab.paneId))
            } label: {
                Label("Tab öffnen", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } else {
            Text("Kein wartender Planungs-Tab auf diesem Host. Freigeben in einer Claude-Sitzung im Repo mit:")
                .foregroundStyle(.secondary)
            HStack {
                Text(verbatim: item.approveCommand)
                    .font(.body.monospaced())
                    .selectableText()
                Spacer()
                Button(copied ? "Kopiert" : "Kopieren") {
                    Platform.copy(item.approveCommand)
                    copied = true
                }
            }
        }
    }

    private func send(_ answer: Approvals.Answer, on connection: HostConnection) {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await store.approvals.answer(answer, for: item, on: connection)
            } catch {
                self.error = (error as? Approvals.AnswerFailure)?.localizedDescription ?? inputErrorMessage(error)
            }
        }
    }

    /// The overview's Markdown with its line breaks; `###` headings bold,
    /// since only inline syntax is rendered.
    static func rendered(_ markdown: String) -> AttributedString {
        let text = markdown
            .components(separatedBy: "\n")
            .map { line in
                line.hasPrefix("### ") ? "**\(line.dropFirst(4))**" : line
            }
            .joined(separator: "\n")
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

extension View {
    /// Loads the approvals when the view appears and when a host connects,
    /// and shows the selected one.
    func approvals(_ store: HostStore, selected: Binding<Approvals.Item?>, open: @escaping (SpaceRef) -> Void) -> some View {
        task(id: store.connections.filter(\.isLive).map(\.id)) {
            await store.approvals.load(store.connections)
        }
        .sheet(item: selected) { item in
            ApprovalDetail(item: item, open: open)
                .environment(store)
        }
    }
}
#endif
