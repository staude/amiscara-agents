import SwiftUI

#if !os(tvOS)
/// The last 30 days of Claude Code tokens on a host (#302), per day with
/// the estimated cost, unfolding into model and folder. Covers the working
/// directories of the open Claude agents, like the dashboard.
struct UsageDetailView: View {
    let connection: HostConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Tokens · \(connection.config.name)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Neu lesen", systemImage: "arrow.clockwise") {
                            Task { await connection.usage.loadHistory() }
                        }
                        .disabled(connection.usage.historyPhase == .loading)
                    }
                }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { await connection.usage.loadHistory() }
    }

    @ViewBuilder
    private var content: some View {
        let usage = connection.usage
        if let history = usage.history {
            let days = Self.days(history, prices: .shared)
            List {
                Section {
                    LabeledContent("30 Tage", value: UsageStore.sum(history, from: UsageStore.historyStart(), prices: .shared).summary)
                    if usage.historyPhase == .loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if case .failed(let message) = usage.historyPhase {
                        Text("Nicht neu gelesen: \(message)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Geschätzt mit den Preisen aus den Einstellungen, in US-Dollar. Gezählt werden die Ordner der offenen Claude-Agents.")
                }
                Section("Tage") {
                    if days.isEmpty {
                        Text("Keine Tokens in diesen Ordnern.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(days) { day in
                        DisclosureGroup {
                            ForEach(day.parts) { part in
                                LabeledContent {
                                    Text(part.usage.summary)
                                } label: {
                                    Text(part.model)
                                    Text(part.folder)
                                }
                            }
                        } label: {
                            LabeledContent(day.date.formatted(.dateTime.weekday(.abbreviated).day().month()), value: day.usage.summary)
                        }
                    }
                }
            }
        } else {
            switch usage.historyPhase {
            case .filesOff:
                ContentUnavailableView("Kein Dateizugriff", systemImage: "folder.badge.questionmark",
                                       description: Text("Tokens und Kosten brauchen Dateizugriff wie „Bilder hochladen“ (Host bearbeiten)."))
            case .failed(let message):
                ContentUnavailableView("Nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(message))
            case .idle, .loading:
                ProgressView {
                    Text("Liest die Sitzungsdateien der letzten 30 Tage. Beim ersten Mal dauert das eine Weile.")
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    struct Day: Identifiable {
        let date: Date
        let usage: WidgetSnapshot.Usage
        let parts: [Part]
        var id: Date { date }
    }

    struct Part: Identifiable {
        let model: String
        let folder: String
        let usage: WidgetSnapshot.Usage
        var id: String { model + "\n" + folder }
    }

    /// The days with tokens, newest first; each split by model and folder,
    /// most tokens first.
    static func days(_ buckets: [UsageBucket], prices: UsagePrices) -> [Day] {
        let calendar = Calendar.current
        let start = UsageStore.historyStart()
        let byDay = Dictionary(grouping: buckets.filter { $0.start >= start }) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted(by: >).compactMap { date in
            let buckets = byDay[date] ?? []
            let end = calendar.date(byAdding: .day, value: 1, to: date) ?? .distantFuture
            let usage = UsageStore.sum(buckets, from: date, to: end, prices: prices)
            guard usage.tokens > 0 else { return nil }
            let parts = Dictionary(grouping: buckets) { "\($0.model)\n\($0.cwd)" }.values.compactMap { group -> Part? in
                guard let first = group.first else { return nil }
                return Part(
                    model: first.model,
                    folder: first.cwd,
                    usage: UsageStore.sum(group, from: date, to: end, prices: prices)
                )
            }
            return Day(date: date, usage: usage, parts: parts.sorted { $0.usage.tokens > $1.usage.tokens })
        }
    }
}
#endif

#if !os(tvOS)
/// The price table the costs are estimated with (#302): dollars per
/// million tokens per model, editable, with the list prices to go back to.
struct UsagePricesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prices = UsagePrices.shared
    @State private var newModel = ""

    var body: some View {
        NavigationStack {
            Form {
                ForEach($prices.prices) { $price in
                    Section(price.model) {
                        priceField("Input", value: $price.input)
                        priceField("Output", value: $price.output)
                        priceField("Cache schreiben (5 Min.)", value: $price.cacheWrite5m)
                        priceField("Cache schreiben (1 Std.)", value: $price.cacheWrite1h)
                        priceField("Cache lesen", value: $price.cacheRead)
                        Button("Entfernen", role: .destructive) {
                            prices.prices.removeAll { $0.model == price.model }
                        }
                    }
                }
                Section {
                    TextField("Modell-ID, z. B. claude-opus-5-5", text: $newModel)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Modell hinzufügen") {
                        prices.prices.append(ModelPrice(model: trimmedModel, input: 0, output: 0, cacheRead: 0))
                        newModel = ""
                    }
                    .disabled(trimmedModel.isEmpty || prices.prices.contains { $0.model == trimmedModel })
                } footer: {
                    Text("US-Dollar je Million Tokens. Ein Modell ohne Preis zählt bei den Tokens mit, aber nicht bei den Kosten.")
                }
                Section {
                    Button("Listenpreise wiederherstellen") { prices.reset() }
                        .disabled(prices.isDefault)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Preise")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var trimmedModel: String {
        newModel.trimmingCharacters(in: .whitespaces)
    }

    private func priceField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}

/// "Tageskosten im Widget" and the price table, in the settings (Mac) or
/// the sidebar's menu (iOS).
struct UsageWidgetToggle: View {
    @Environment(HostStore.self) private var store
    @AppStorage(UsageStore.widgetKey) private var enabled = false

    var body: some View {
        Toggle("Tageskosten im Widget", isOn: $enabled)
            .onChange(of: enabled) {
                if enabled {
                    Task {
                        for connection in store.connections { await connection.usage.refreshToday() }
                    }
                }
                store.widgets.publish(store, force: true)
            }
    }
}
#endif
