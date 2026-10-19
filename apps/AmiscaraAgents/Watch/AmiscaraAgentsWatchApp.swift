import CloudKit
import SwiftUI
import WatchKit
import WidgetKit

/// Amiscara Agents on the Apple Watch (#157): who waits, what is asked, and
/// a tap to answer. No terminal, no host settings; that stays on the
/// iPhone.
@main
struct AmiscaraAgentsWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var store: WatchStore { delegate.store }

    var body: some Scene {
        WindowGroup {
            AgentListView()
                .environment(store)
                .tint(.amiscaraAccent)
                // A tapped complication: its first waiting agent.
                .onOpenURL { url in
                    guard let target = WidgetSnapshot.parseOpenURL(url) else { return }
                    store.openRequest = AgentRef(hostID: target.host, paneID: target.paneID)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await store.refresh() }
            }
        }
    }
}

extension Color {
    /// The app's accent in dark mode, which the Watch always uses.
    static let amiscaraAccent = Color(red: 0x2F / 255, green: 0xD1 / 255, blue: 0xA5 / 255)
}

/// Owns the store, so a silent push finds it without a window, and
/// registers for the board pushes that keep the complications current
/// (#158).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let store = WatchStore()

    static let boardSubscriptionID = "\(CloudBoard.recordType)-v1"

    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
        Task { await Self.subscribeToBoards() }
    }

    /// The same subscription the iPhone saves; saving it again is
    /// harmless. Until the Mac wrote its first board iCloud refuses it,
    /// and the next launch tries again.
    private static func subscribeToBoards() async {
        let subscription = CKQuerySubscription(
            recordType: CloudBoard.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: boardSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await CloudPush.container.privateCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
    }

    /// A new board from the Mac: fetch it and redraw the complications.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == Self.boardSubscriptionID
        else { return .noData }
        await store.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        return .newData
    }
}
