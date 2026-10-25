#if !os(tvOS)
import SwiftUI
#if os(iOS)
import SafariServices
#endif

/// Pages agents on the hosts want opened (#247), one card each. Opening
/// forwards a page on the host's `localhost` through the connection and
/// takes the request back on the host, so other devices drop it too;
/// ignoring hides it on this device only. On iPhone and iPad the page opens
/// inside the app: in Safari the app would go to the background and the
/// forwarding break off.
struct OpenRequestBanner: View {
    @Environment(HostStore.self) private var store
    @State private var errors: [String: String] = [:]
    @State private var opening: Set<String> = []
    #if os(iOS)
    @State private var page: SafariPage?
    #endif

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.openRequests) { pending in
                card(pending)
            }
        }
        .frame(maxWidth: 520)
        .padding()
        #if os(iOS)
        .sheet(item: $page) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        #endif
    }

    private func card(_ pending: PendingOpen) -> some View {
        let request = pending.request
        let space = request.workspaceLabel.isEmpty ? pending.connection.config.name : request.workspaceLabel
        return VStack(alignment: .leading, spacing: 6) {
            Label("Agent in \(space) möchte eine Seite öffnen", systemImage: "safari")
                .font(.headline)
            Text(request.url)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .selectableText()
            if let error = errors[pending.key] {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Ignorieren") {
                    store.ignoredOpenRequests.insert(pending.key)
                }
                Button("Öffnen") {
                    Task { await open(pending) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(opening.contains(pending.key))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }

    private func open(_ pending: PendingOpen) async {
        opening.insert(pending.key)
        defer { opening.remove(pending.key) }
        errors[pending.key] = nil
        do {
            let address = try await pending.connection.openAddress(for: pending.request)
            guard let url = URL(string: address) else {
                errors[pending.key] = String(localized: "Ungültige Adresse: \(address)")
                return
            }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            page = SafariPage(url: url)
            #endif
            store.ignoredOpenRequests.insert(pending.key)
            await pending.connection.dismiss(pending.request)
        } catch {
            errors[pending.key] = inputErrorMessage(error)
        }
    }
}

#if os(iOS)
private struct SafariPage: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
#endif
