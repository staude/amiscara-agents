import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
#endif

/// "Share → Amiscara Agents" (#225): text, links and images from another
/// app for an agent's composer. The extension holds no SSH session, so it
/// hands the share to the app (`PendingShare`) and posts a notification
/// that opens the app at the chosen agent with the composer filled. On the
/// Mac (#236) it opens the app itself.
#if os(macOS)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 560))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let view = ShareView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = NSHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.width, .height]
        self.view.addSubview(host.view)
        preferredContentSize = self.view.frame.size
    }
}
#else
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
#endif

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
    /// The text goes over as a Markdown file with `prompt` (#236).
    @State private var asFile = false
    @State private var prompt = Handoff.prompt
    @State private var images: [(name: String, data: Data)] = []
    @State private var targets: [Target] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var error: String?
    /// The note that nothing readable was shared; gone once there is text.
    @State private var nothingShared = false

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
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                }
                if images.isEmpty && !loading {
                    Toggle("Als Übergabe-Datei", isOn: $asFile)
                }
                if handsOverFile {
                    Section("Übergabe") {
                        ScrollView {
                            Text(previewText)
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                    Section("Prompt") {
                        TextField("Prompt", text: $prompt, axis: .vertical)
                            .lineLimit(2...6)
                    }
                } else {
                    Section("Prompt") {
                        if loading {
                            ProgressView()
                        }
                        TextField("Prompt", text: $text, axis: .vertical)
                            .lineLimit(3...12)
                    }
                }
                if !images.isEmpty {
                    Section {
                        Text("\(images.count) Bilder werden angehängt.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Group {
                        if handsOverFile {
                            Text("Amiscara Agents öffnet den Agent mit dem Prompt und der Datei im Eingabefeld; gesendet wird erst dort.")
                        } else {
                            Text("Amiscara Agents öffnet den Agent mit diesem Prompt; gesendet wird erst dort.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("An Agent senden")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        .onChange(of: text) {
            if nothingShared && !text.isEmpty {
                nothingShared = false
                error = nil
            }
        }
    }

    /// Images go up as images; the switch is for text only.
    private var handsOverFile: Bool { asFile && images.isEmpty }

    /// The start of a long text; all of it goes into the file.
    private var previewText: String {
        text.count > 4000 ? String(text.prefix(4000)) + " …" : text
    }

    private func load() async {
        let snapshot = WidgetSnapshot.load()
        targets = snapshot.agents.map { Target(hostID: $0.host.id, hostName: $0.host.name, agent: $0.agent) }
        // Waiting agents come first.
        selection = targets.first?.id
        var parts: [String] = []
        var loaded: [(name: String, data: Data)] = []
        var markdown = false
        for provider in providers {
            // Files from other apps may come as Markdown content, no URL.
            if let markdownType = UTType("net.daringfireball.markdown"),
               provider.registeredContentTypes.contains(where: { $0.conforms(to: markdownType) }) {
                markdown = true
            }
            // Images first: attachments from Files or Mail also carry a
            // file URL.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await imageData(provider) {
                    loaded.append((name: "image-\(loaded.count + 1).\(data.ext)", data: data.data))
                }
            } else if let url = await object(URL.self, from: provider) {
                if url.isFileURL {
                    // A file that is no text (a PDF, say) adds nothing.
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        parts.append(content)
                        markdown = markdown || ["md", "markdown"].contains(url.pathExtension.lowercased())
                    }
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
        asFile = Handoff.suggestsFile(text: text, isMarkdownFile: markdown)
        if text.isEmpty && loaded.isEmpty && !providers.isEmpty {
            error = String(localized: "Das Geteilte enthält keinen Text und kein Bild.")
        }
        nothingShared = error != nil
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
        let shared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = handsOverFile
        if file && shared.count > Handoff.maxLength {
            error = String(localized: "Der Text ist zu lang für eine Übergabe.")
            return
        }
        // Kept for next time; an empty prompt is the default one.
        if file { Handoff.prompt = prompt }
        let share = PendingShare(
            hostID: target.hostID,
            workspaceID: target.agent.workspaceID,
            paneID: target.agent.paneID,
            text: file ? Handoff.prompt : shared,
            images: images.map(\.name),
            handoff: file ? shared : nil,
            created: .now
        )
        do {
            try PendingShare.save(share, imageData: images)
        } catch {
            self.error = error.localizedDescription
            return
        }
        #if os(macOS)
        // The Mac shows no notification for this: the app opens at once and
        // takes the share (ContentView).
        if let url = URL(string: "amiscara-agents://share") {
            NSWorkspace.shared.open(url)
        }
        #else
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Prompt für \(target.agent.name) bereit")
        content.body = String(localized: "Tippen, um ihn in Amiscara Agents zu senden.")
        content.categoryIdentifier = PendingShare.notificationCategory
        content.userInfo = ["host": target.hostID.uuidString, "workspace": target.agent.workspaceID, "pane": target.agent.paneID]
        let request = UNNotificationRequest(identifier: "pending-share", content: content, trigger: nil)
        // Registered before the extension goes away.
        try? await UNUserNotificationCenter.current().add(request)
        #endif
        done()
    }
}
