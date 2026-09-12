import SwiftUI
import SwiftData

@main
struct TransitGoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    Prewarm.run()
                    await AnnouncementService.shared.refresh()
                }
                .task(priority: .background) {
                    // Warm the nationwide YouBike name-search catalog a few cities at a
                    // time, so searching "全台灣" doesn't cold-start into TDX rate limits.
                    await BikeStationCatalog.shared.prewarmAll()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await AnnouncementService.shared.refresh() }
                    }
                }
        }
        .modelContainer(for: [FavoriteItem.self, RailTicket.self])
    }
}
