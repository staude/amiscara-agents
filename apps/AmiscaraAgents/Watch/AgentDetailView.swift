import SwiftUI

/// One agent: its state and, while it waits, what it asks with the answer
/// keys below. The keys go to the iPhone, which sends them to herdr.
struct AgentDetailView: View {
    let ref: AgentRef
    @Environment(WatchStore.self) private var store
    @State private var excerpt: Excerpt?
    @State private var loadingExcerpt = false
    @State private var sending: String?
    @State private var result: Result?

    enum Result: Equatable {
        case sent(String)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            if let entry = store.agent(ref) {
                VStack(alignment: .leading, spacing: 8) {
                    header(host: entry.host, agent: entry.agent)
                    if entry.agent.state == .blocked {
                        question
                        keys
                    }
                    if let result {
                        resultLabel(result)
                    }
                }
            } else {
                Text("Diesen Agent gibt es nicht mehr.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.agent(ref)?.agent.name ?? "")
        .task(id: store.agent(ref)?.agent.state) {
            guard store.agent(ref)?.agent.state == .blocked else { return }
            loadingExcerpt = true
            excerpt = await store.excerpt(for: ref)
            loadingExcerpt = false
        }
    }

    private func header(host: WidgetSnapshot.Host, agent: WidgetSnapshot.Agent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(agent.state.label, systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(agent.state.color)
            Text(agent.place)
                .font(.footnote)
            Text(host.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var question: some View {
        if let excerpt {
            VStack(alignment: .leading, spacing: 4) {
                Text(excerpt.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let since = excerpt.since {
                    Text("seit \(since, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else if loadingExcerpt {
            ProgressView()
        } else {
            Text("Kein Bildschirmauszug. Er kommt von der Mac-App auf dem Host.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var keys: some View {
        let answers = AgentNotification.answers
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(answers.prefix(3), id: \.key) { answer in
                    keyButton(answer.key, title: answer.title)
                }
            }
            HStack(spacing: 6) {
                ForEach(answers.dropFirst(3), id: \.key) { answer in
                    keyButton(answer.key, title: answer.title)
                }
            }
        }
        .disabled(sending != nil)
    }

    private func keyButton(_ key: String, title: String) -> some View {
        Button {
            send(key, title: title)
        } label: {
            if sending == key {
                ProgressView()
            } else {
                Text(title).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
    }

    private func resultLabel(_ result: Result) -> some View {
        switch result {
        case .sent(let title):
            Label("\(title) gesendet", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func send(_ key: String, title: String) {
        sending = key
        result = nil
        Task {
            let error = await store.answer(key, to: ref)
            sending = nil
            result = error.map(Result.failed) ?? .sent(title)
        }
    }
}
