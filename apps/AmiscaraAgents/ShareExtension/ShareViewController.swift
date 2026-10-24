import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// "Share → Amiscara Agents" (#225): text, links and images from another
/// app for an agent's composer. The extension holds no SSH session, so it
/// hands the share to the app (`PendingShare`) and posts a notification
/// that opens the app at the chosen agent with the composer filled.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let view = ShareView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct Target: Identifiable {
    let hostID: UUID
    let hostName: String
    let agent: WidgetSnapshot.Agent

    var id: String { "\(hostID.uuidString)/\(agent.paneID)" }
}

private struct ShareView: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void

    @State private var text = ""
    @State private var images: [(name: String, data: Data)] = []
    @State private var targets: [Target] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if targets.isEmpty && !loading {
                    Text("Keine Agents bekannt. Öffnen Sie Amiscara Agents einmal, damit die Liste hier erscheint.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: $selection) {
                        ForEach(targets) { target in
                            VStack(alignment: .leading) {
                                Text(target.agent.name)
                                Text("\(target.hostName) · \(target.agent.place)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(target.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Prompt") {
                    if loading {
                        ProgressView()
                    }
                    TextField("Prompt", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                }
                if !images.isEmpty {
                    Section {
                        Text("\(images.count) Bilder werden angehängt.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Amiscara Agents öffnet den Agent mit diesem Prompt; gesendet wird erst dort.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("An Agent senden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Weiter") { Task { await handOver() } }
                        .disabled(loading || selection == nil || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let snapshot = WidgetSnapshot.load()
        targets = snapshot.agents.map { Target(hostID: $0.host.id, hostName: $0.host.name, agent: $0.agent) }
        // Waiting agents come first.
        selection = targets.first?.id
        var parts: [String] = []
        var loaded: [(name: String, data: Data)] = []
        for provider in providers {
            // Images first: attachments from Files or Mail also carry a
            // file URL.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await imageData(provider) {
                    loaded.append((name: "image-\(loaded.count + 1).\(data.ext)", data: data.data))
                }
            } else if let url = await object(URL.self, from: provider) {
                if url.isFileURL, let content = try? String(contentsOf: url, encoding: .utf8) {
                    parts.append(content)
                } else {
                    parts.append(url.absoluteString)
                }
            } else if let shared = await sharedText(provider) {
                parts.append(shared)
            }
        }
        images = loaded
        // Whatever the user typed meanwhile stays, after the shared text.
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ([parts.joined(separator: "\n")] + (typed.isEmpty ? [] : [typed]))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        loading = false
    }

    private func object<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        guard provider.canLoadObject(ofClass: T.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: T.self) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    /// Plain text, else rich text (RTF, HTML) as plain text.
    private func sharedText(_ provider: NSItemProvider) async -> String? {
        if let plain = await object(String.self, from: provider) { return plain }
        for (type, document) in [(UTType.rtf, NSAttributedString.DocumentType.rtf), (UTType.html, .html)]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
            }
            if let data, let rich = try? NSAttributedString(data: data, options: [.documentType: document], documentAttributes: nil) {
                return rich.string
            }
        }
        return nil
    }

    /// The image in a format agents read; the camera's RAW only when there
    /// is nothing else, it can be too big for an extension.
    private func imageData(_ provider: NSItemProvider) async -> (data: Data, ext: String)? {
        let types = provider.registeredContentTypes.filter { $0.conforms(to: .image) }
        let preferred: [UTType] = [.jpeg, .heic, .png]
        let type = preferred.first { wanted in types.contains { $0.conforms(to: wanted) } }
            ?? types.first { !$0.conforms(to: .rawImage) }
            ?? types.first
            ?? .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data.map { ($0, type.preferredFilenameExtension ?? "png") })
            }
        }
    }

    private func handOver() async {
        guard let target = targets.first(where: { $0.id == selection }) else { return }
        let share = PendingShare(
            hostID: target.hostID,
            workspaceID: target.agent.workspaceID,
            paneID: target.agent.paneID,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            images: images.map(\.name),
            created: .now
        )
        do {
            try PendingShare.save(share, imageData: images)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Prompt für \(target.agent.name) bereit")
        content.body = String(localized: "Tippen, um ihn in Amiscara Agents zu senden.")
        content.categoryIdentifier = PendingShare.notificationCategory
        content.userInfo = ["host": target.hostID.uuidString, "workspace": target.agent.workspaceID, "pane": target.agent.paneID]
        let request = UNNotificationRequest(identifier: "pending-share", content: content, trigger: nil)
        // Registered before the extension goes away.
        try? await UNUserNotificationCenter.current().add(request)
        done()
    }
}
