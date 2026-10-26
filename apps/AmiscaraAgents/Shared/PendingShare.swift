import Foundation

/// Text, links and images shared to Amiscara Agents from another app
/// (#225). The share extension cannot reach a host itself (no SSH session,
/// no keys) and iOS lets it not open the app, so it leaves the share in
/// the App Group; the app opens that agent with the composer filled, and
/// the user sends it from there. One share at a time; a newer one replaces
/// it. The handoff sheet (#236) takes the same way from inside the app.
struct PendingShare: Codable, Equatable {
    let hostID: UUID
    let workspaceID: String
    let paneID: String
    /// What goes into the composer: shared text and links, edited.
    let text: String
    /// Image files next to the share, by name.
    let images: [String]
    /// A handoff from another AI tool (#236): Markdown the composer
    /// attaches as a file; `text` is then the prompt that goes with it.
    /// Optional, so shares saved before it still decode.
    var handoff: String? = nil
    let created: Date
    /// The app brought the user to the pane once; it does not again.
    var opened = false

    /// Older shares are dropped: the user moved on.
    static let maxAge: TimeInterval = 60 * 60

    private static var directory: URL? {
        WidgetSnapshot.directory?.appending(path: "PendingShare", directoryHint: .isDirectory)
    }

    private static var fileURL: URL? {
        directory?.appending(path: "share.json")
    }

    /// Saves the share and its images, replacing an older one.
    static func save(_ share: PendingShare, imageData: [(name: String, data: Data)]) throws {
        guard let directory, let fileURL else { throw CocoaError(.fileNoSuchFile) }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for image in imageData {
            try image.data.write(to: directory.appending(path: image.name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try JSONEncoder().encode(share).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The waiting share, if there is a fresh one.
    static func peek() -> PendingShare? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let share = try? JSONDecoder().decode(PendingShare.self, from: data)
        else { return nil }
        guard Date.now.timeIntervalSince(share.created) < maxAge else {
            clear()
            return nil
        }
        return share
    }

    /// Takes the share for this pane with its images and removes it.
    static func take(hostID: UUID, paneID: String) -> (share: PendingShare, images: [Data])? {
        guard let share = peek(), share.hostID == hostID, share.paneID == paneID, let directory else { return nil }
        let images = share.images.compactMap { try? Data(contentsOf: directory.appending(path: $0)) }
        clear()
        return (share, images)
    }

    /// Notes that the app opened the share's pane, so becoming active
    /// again does not pull the user back there.
    static func markOpened() {
        guard var share = peek(), let fileURL else { return }
        share.opened = true
        try? JSONEncoder().encode(share).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The notification that brings the user to the app, posted by the
    /// extension; tapping it opens the agent like an agent notification.
    static let notificationCategory = "pending-share"

    /// Posted in the app when a notification was opened, so a composer on
    /// screen can take its share.
    static let arrived = Notification.Name("net.staude.amiscara.agents.pendingShareArrived")
}
