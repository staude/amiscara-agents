import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

#if !os(tvOS)
/// One sound each for "agent waits" and "agent is done" (#336). On the Mac
/// in the settings window, on iOS in the "Erscheinungsbild" menu. The choice
/// belongs to the device; it does not travel through iCloud.
struct NotificationSoundSettings: View {
    var body: some View {
        NotificationSoundPicker(waiting: true)
        NotificationSoundPicker(waiting: false)
    }
}

private struct NotificationSoundPicker: View {
    let waiting: Bool
    @AppStorage private var stored: String
    @State private var player: AVAudioPlayer?
    @State private var importing = false
    @State private var failure: String?

    /// The tag of the entry that opens the file dialog; no sound's name.
    private static let pickFile = "pick-file"

    init(waiting: Bool) {
        self.waiting = waiting
        _stored = AppStorage(wrappedValue: NotificationSound.fallback(waiting: waiting).stored, NotificationSound.key(waiting: waiting))
    }

    private var choice: NotificationSound { NotificationSound(stored: stored, waiting: waiting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(waiting ? "Wartet" : "Fertig", selection: selection) {
                    ForEach(options, id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                    #if os(macOS)
                    Divider()
                    Text("Eigene Datei …").tag(Self.pickFile)
                    #endif
                }
                #if os(macOS)
                Button("Probehören", systemImage: "play.circle") { preview() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(choice == .none)
                #endif
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        #if os(macOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fileTypes) { result in
            switch result {
            case .success(let url): add(url)
            case .failure(let error):
                // Closing the dialog is no error.
                if (error as? CocoaError)?.code != .userCancelled { failure = error.localizedDescription }
            }
        }
        #endif
    }

    private var selection: Binding<String> {
        Binding(
            get: { choice.stored },
            set: { new in
                if new == Self.pickFile {
                    importing = true
                    return
                }
                stored = new
                failure = nil
                preview()
                #if os(iOS)
                // The pushes through iCloud name their sound in the subscription.
                Task { await CloudPushSubscriptions.shared.install() }
                #endif
            }
        )
    }

    // MARK: List

    private var options: [(id: String, title: String)] {
        var list: [(id: String, title: String)] = [
            (NotificationSound.none.stored, String(localized: "Kein Ton")),
            (NotificationSound.standard.stored, String(localized: "Standardton")),
        ]
        list += NotificationSound.appTones.map { (NotificationSound.app($0).stored, Self.title(ofTone: $0)) }
        #if os(macOS)
        list += Self.systemSounds.map { (NotificationSound.system($0).stored, $0) }
        list += Self.userFiles.map { (NotificationSound.file($0).stored, Self.title(ofFile: $0)) }
        #endif
        // A file that has gone since still shows as the choice.
        if !list.contains(where: { $0.id == choice.stored }) {
            list.append((choice.stored, Self.title(of: choice)))
        }
        return list
    }

    private static func title(ofTone name: String) -> String {
        switch name {
        case "chime": String(localized: "Glocke")
        case "rising": String(localized: "Aufsteigend")
        case "falling": String(localized: "Absteigend")
        case "knock": String(localized: "Klopfen")
        default: name
        }
    }

    private static func title(ofFile name: String) -> String {
        let bare = name.hasPrefix(NotificationSound.filePrefix) ? String(name.dropFirst(NotificationSound.filePrefix.count)) : name
        return (bare as NSString).deletingPathExtension
    }

    private static func title(of sound: NotificationSound) -> String {
        switch sound {
        case .none: String(localized: "Kein Ton")
        case .standard: String(localized: "Standardton")
        case .app(let name): title(ofTone: name)
        case .system(let name): name
        case .file(let name): title(ofFile: name)
        }
    }

    #if os(macOS)
    private static let systemSoundsFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    private static var systemSounds: [String] {
        names(in: systemSoundsFolder, prefix: "", extension: "aiff")
            .map { ($0 as NSString).deletingPathExtension }
    }

    /// The files added through "Eigene Datei …".
    private static var userFiles: [String] {
        names(in: NotificationSound.userSoundsFolder, prefix: NotificationSound.filePrefix, extension: nil)
    }

    private static func names(in folder: URL, prefix: String, extension ext: String?) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return all
            .filter { $0.hasPrefix(prefix) && (ext == nil || ($0 as NSString).pathExtension == ext) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Formats the system takes for a notification sound.
    private static let fileTypes: [UTType] = [.aiff, .wav, UTType("com.apple.coreaudio-format")].compactMap { $0 }

    /// Copies a chosen file to `~/Library/Sounds`, the only place the system
    /// finds a notification sound, and chooses it.
    private func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent.hasPrefix(NotificationSound.filePrefix)
            ? url.lastPathComponent
            : NotificationSound.filePrefix + url.lastPathComponent
        let folder = NotificationSound.userSoundsFolder
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            stored = NotificationSound.file(name).stored
            failure = nil
            preview()
        } catch {
            failure = String(localized: "Die Datei ließ sich nicht übernehmen: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: Preview

    private func preview() {
        let choice = choice
        switch choice {
        case .none:
            return
        case .standard:
            Task { await Self.previewDefault() }
        case .app(let name):
            play(Bundle.main.url(forResource: name, withExtension: "caf"))
        case .system(let name):
            play(URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff"))
        case .file(let name):
            play(NotificationSound.userSoundsFolder.appendingPathComponent(name))
        }
    }

    private func play(_ url: URL?) {
        guard let url, let sound = try? AVAudioPlayer(contentsOf: url) else { return }
        player = sound
        sound.play()
    }

    /// The default sound belongs to the system, so the preview is a local
    /// notification that is withdrawn after a moment.
    private static func previewDefault() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Probe des Mitteilungstons")
        content.sound = .default
        let identifier = "sound-preview"
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        try? await Task.sleep(for: .seconds(3))
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
#endif
