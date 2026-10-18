import TVServices
import UIKit

/// The Top Shelf of Amiscara Agents (#130): when the app sits in the top row
/// of the Apple TV home screen, its agents show there, waiting first. The
/// app writes them into the App Group (`WidgetSnapshot`, as for the widgets
/// on iPhone and Mac) and tells tvOS when they change.
final class ContentProvider: TVTopShelfContentProvider {
    // The completion form: the async one returns a non-Sendable type.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(content())
    }

    private func content() -> (any TVTopShelfContent)? {
        let snapshot = WidgetSnapshot.load()
        let agents = snapshot.agents
        guard !agents.isEmpty else { return nil }
        let waiting = agents.filter { $0.agent.state == .blocked }
        let others = agents.filter { $0.agent.state != .blocked }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        for (title, entries) in [("Wartet", waiting), ("Agents", others)] where !entries.isEmpty {
            let items = entries.prefix(12).map { item(for: $0.agent, host: $0.host, showHost: snapshot.hosts.count > 1) }
            let collection = TVTopShelfItemCollection(items: Array(items))
            collection.title = title
            sections.append(collection)
        }
        return TVTopShelfSectionedContent(sections: sections)
    }

    private func item(for agent: WidgetSnapshot.Agent, host: WidgetSnapshot.Host, showHost: Bool) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "\(host.id.uuidString)/\(agent.paneID)")
        item.title = showHost ? "\(agent.place) · \(host.name)" : agent.place
        item.imageShape = .hdtv
        if let url = Self.cardImage(for: agent) {
            item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
        }
        let open = WidgetSnapshot.openURL(host: host.id, workspaceID: agent.workspaceID, paneID: agent.paneID)
        item.playAction = TVTopShelfAction(url: open)
        item.displayAction = TVTopShelfAction(url: open)
        return item
    }

    /// A card in the agent's state colour with its state and name, drawn
    /// into the extension's caches.
    private static func cardImage(for agent: WidgetSnapshot.Agent) -> URL? {
        let size = CGSize(width: 800, height: 450)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.04, green: 0.16, blue: 0.18, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            agent.state.uiColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))
            let state = NSAttributedString(string: agent.state.text, attributes: [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: agent.state.uiColor,
            ])
            state.draw(at: CGPoint(x: 70, y: 110))
            let name = NSAttributedString(string: agent.name, attributes: [
                .font: UIFont.systemFont(ofSize: 52, weight: .medium),
                .foregroundColor: UIColor.white,
            ])
            name.draw(in: CGRect(x: 70, y: 220, width: size.width - 110, height: 70))
            let place = NSAttributedString(string: agent.place, attributes: [
                .font: UIFont.systemFont(ofSize: 40),
                .foregroundColor: UIColor(white: 1, alpha: 0.7),
            ])
            place.draw(in: CGRect(x: 70, y: 300, width: size.width - 110, height: 60))
        }
        // In the App Group, so the system can read it for the Top Shelf.
        guard let data = image.pngData(), let dir = WidgetSnapshot.directory else { return nil }
        let url = dir.appending(path: "card-\(agent.state.rawValue)-\(abs(agent.paneID.hashValue ^ agent.name.hashValue ^ agent.place.hashValue)).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return url
    }
}

private extension WidgetSnapshot.State {
    var uiColor: UIColor {
        switch self {
        case .blocked: .systemOrange
        case .working: .systemBlue
        case .done: .systemGreen
        case .idle, .unknown: .systemGray
        }
    }

    var text: String {
        switch self {
        case .blocked: String(localized: "wartet")
        case .working: String(localized: "arbeitet")
        case .done: String(localized: "fertig")
        case .idle: String(localized: "bereit")
        case .unknown: String(localized: "unbekannt")
        }
    }
}
