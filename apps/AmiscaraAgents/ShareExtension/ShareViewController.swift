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
                    Button("Weiter", action: handOver)
                        .disabled(selection == nil || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
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
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                parts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await imageData(provider) {
                    images.append((name: "image-\(images.count + 1).\(data.ext)", data: data.data))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let shared = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                parts.append(shared)
            }
        }
        text = parts.joined(separator: "\n")
        loading = false
    }

    private func imageData(_ provider: NSItemProvider) async -> (data: Data, ext: String)? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data.map { ($0, type.preferredFilenameExtension ?? "png") })
            }
        }
    }

    private func handOver() {
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
        UNUserNotificationCenter.current().add(request) { _ in }
        done()
    }
}
