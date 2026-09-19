import SwiftUI
import SwiftData

@main
struct TransitGoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// One container for the whole app, built through the migration plan (V1 -> V2 adds favorite trips).
    /// If the store can't be opened the app must still launch: it falls back to an in-memory store
    /// rather than crashing (and never deletes the on-disk data).
    private static let container: ModelContainer = {
        do { return try AppStore.makeContainer() }
        catch {
            NSLog("[store] could not open the persistent store: %@", String(describing: error))
            return (try? AppStore.makeContainer(inMemory: true)) ?? { fatalError("no SwiftData container available") }()
        }
    }()

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
        .modelContainer(Self.container)
    }
}
