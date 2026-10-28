import SwiftUI

#if !os(tvOS)

/// What happened on a host on one day (#301): prompts to Claude agents,
/// their finished turns and the commits of every space, by time, for
/// today and the six days before. Read only and kept only while the sheet
/// is open; the host runs Git in a short-lived tab like the diff.
struct DailyLogView: View {
    let connection: HostConnection
    @Environment(\.dismiss) private var dismiss
    /// Days back from today, 0 to 6.
    @State private var day = 0
    @State private var logs: [Int: DailyLog] = [:]
    @State private var errors: [Int: String] = [:]
    @State private var loadingDay: Int?
    #if canImport(FoundationModels)
    @State private var summary = DailyLogSummary()
    #endif

    private static let days = 7

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(connection.config.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neu laden", systemImage: "arrow.clockwise") {
                        Task { await load(force: true) }
                    }
                    .disabled(loadingDay == day)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
        .task(id: day) {
            #if canImport(FoundationModels)
            summary.reset()
            #endif
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Tag", selection: $day) {
                    ForEach(0..<Self.days, id: \.self) { offset in
                        Text(Self.name(ofDay: offset)).tag(offset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                #if canImport(FoundationModels)
                if PaneSummary.isAvailable, let items = logs[day]?.items, !items.isEmpty, summary.state == .offered {
                    Button("Zusammenfassen", systemImage: "sparkles") {
                        Task { await summary.summarize(items) }
                    }
                }
                #endif
            }
            #if canImport(FoundationModels)
            switch summary.state {
            case .offered:
                EmptyView()
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fasse zusammen …").foregroundStyle(.secondary)
                }
                .font(.callout)
            case .done(let text):
                Label {
                    Text(text).selectableText()
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                }
                .font(.callout)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectableText()
            }
            #endif
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let log = logs[day] {
            if log.items.isEmpty {
                ContentUnavailableView {
                    Label("Keine Einträge.", systemImage: "calendar")
                } description: {
                    Text("An diesem Tag gab es keine Aufträge an Claude und keine Commits.")
                    if let error = errors[day] {
                        Text(error).foregroundStyle(.red)
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(Array(log.items.enumerated()), id: \.offset) { _, item in
                            DailyItemRow(item: item)
                        }
                    } footer: {
                        if log.truncated {
                            Label("Nicht alle Claude-Verläufe wurden bis zum Tagesbeginn gelesen; frühe Einträge können fehlen.", systemImage: "scissors")
                        }
                        // A failed reload keeps the last list; say it is old.
                        if let error = errors[day] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }
        } else if let error = errors[day], loadingDay != day {
            ContentUnavailableView("Tag nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Der Tag wird gelesen …")
        }
    }

    /// Loads the selected day unless it is there already or `force`.
    private func load(force: Bool = false) async {
        let offset = day
        guard force || logs[offset] == nil, loadingDay != offset else { return }
        loadingDay = offset
        defer {
            if loadingDay == offset { loadingDay = nil }
        }
        let (since, until) = Self.bounds(ofDay: offset)
        do {
            logs[offset] = try await connection.dailyLog(since: since, until: until)
            errors[offset] = nil
            #if canImport(FoundationModels)
            // A summary of the old list no longer fits.
            if force, offset == day { summary.reset() }
            #endif
        } catch {
            errors[offset] = inputErrorMessage(error)
        }
    }

    /// Start of the day `offset` days back and start of the day after.
    private static func bounds(ofDay offset: Int) -> (Date, Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let since = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        let until = calendar.date(byAdding: .day, value: 1, to: since) ?? .now
        return (since, until)
    }

    /// "Heute", "Gestern", then weekday and date.
    private static func name(ofDay offset: Int) -> String {
        switch offset {
        case 0: String(localized: "Heute")
        case 1: String(localized: "Gestern")
        default: bounds(ofDay: offset).0.formatted(.dateTime.weekday(.wide).day().month())
        }
    }
}

private struct DailyItemRow: View {
    let item: DailyItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Date(timeIntervalSince1970: TimeInterval(item.timeMs) / 1000), format: .dateTime.hour().minute())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityLabel(label)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.callout)
                    .lineLimit(3)
                if let author = item.author {
                    Text("\(item.place) · \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.kind {
        case .prompt: "text.bubble"
        case .done: "checkmark.circle"
        case .commit: "arrow.triangle.branch"
        }
    }

    private var color: Color {
        switch item.kind {
        case .prompt: .blue
        case .done: .green
        case .commit: .purple
        }
    }

    private var label: String {
        switch item.kind {
        case .prompt: String(localized: "Auftrag")
        case .done: String(localized: "Fertig")
        case .commit: String(localized: "Commit")
        }
    }
}

#endif
