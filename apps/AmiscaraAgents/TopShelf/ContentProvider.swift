import Foundation
import TVServices

/// The Top Shelf of Amiscara Agents (#130): when the app sits in the top row
/// of the Apple TV home screen, its waiting and working agents fill the
/// full-screen shelf of tvOS 26, one page each, waiting first. The app
/// writes them into the App Group (`WidgetSnapshot`, as for the widgets on
/// iPhone and Mac) and tells tvOS when they change.
final class ContentProvider: TVTopShelfContentProvider {
    // The completion form: the async one returns a non-Sendable type.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(content())
    }

    private func content() -> (any TVTopShelfContent)? {
        let snapshot = WidgetSnapshot.load()
        // Idle agents need nobody; without anything active the static image shows.
        let active = snapshot.agents.filter { $0.agent.state == .blocked || $0.agent.state == .working || $0.agent.state == .done }
        guard !active.isEmpty else { return nil }
        let items = active.prefix(10).map { item(for: $0.agent, host: $0.host) }
        return TVTopShelfCarouselContent(style: .details, items: Array(items))
    }

    private func item(for agent: WidgetSnapshot.Agent, host: WidgetSnapshot.Host) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: "\(host.id.uuidString)/\(agent.paneID)")
        item.contextTitle = agent.state.text.uppercased()
        item.title = agent.place
        item.summary = "\(agent.name) · \(host.name)"
        // Prepared backdrops from the bundle: drawing one at run time
        // exceeds the extension's memory and kills it.
        if let url = Bundle.main.url(forResource: "shelf-\(agent.state.rawValue)", withExtension: "jpg") {
            item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
        }
        let open = WidgetSnapshot.openURL(host: host.id, workspaceID: agent.workspaceID, paneID: agent.paneID)
        item.playAction = TVTopShelfAction(url: open)
        item.displayAction = TVTopShelfAction(url: open)
        return item
    }
}

private extension WidgetSnapshot.State {
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
