import XCTest
import SwiftData
@testable import TransitGo

/// "App restart" and "app update" behaviour, on real on-disk stores (not in-memory).
@MainActor
final class PersistenceTests: XCTestCase {

    func testFavoritesAndRecentsSurviveARestart() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var tripID: UUID!

        do {   // first launch
            let container = try AppStore.makeContainer(url: url)
            let store = TripStore(context: container.mainContext)
            let trip = try store.addFavorite(name: "上學", spec: TripSpec(origin: Place.home, destination: Place.school, profile: .leastWalking))
            try store.recordUse(trip, at: Date(timeIntervalSince1970: 5_000))
            try store.recordSearch(TripSpec(origin: Place.hsinchuHSR, destination: Place.taipeiMain), at: Date(timeIntervalSince1970: 6_000))
            tripID = trip.id
            try container.mainContext.save()
        }   // container released: the app "quits"

        do {   // second launch, same file
            let container = try AppStore.makeContainer(url: url)
            let store = TripStore(context: container.mainContext)
            let all = store.favorites()
            XCTAssertEqual(all.count, 1)
            let reloaded = try XCTUnwrap(all.first)
            XCTAssertEqual(reloaded.id, tripID)
            XCTAssertEqual(reloaded.name, "上學")
            XCTAssertEqual(reloaded.spec.origin, Place.home)
            XCTAssertEqual(reloaded.spec.destination, Place.school)
            XCTAssertEqual(reloaded.spec.profile, .leastWalking)
            XCTAssertEqual(reloaded.useCount, 1)
            XCTAssertEqual(reloaded.lastUsedAt, Date(timeIntervalSince1970: 5_000))
            XCTAssertEqual(store.recents().count, 1)
            XCTAssertEqual(store.recents().first?.spec.origin.refId, "1030", "a station keeps its id, not just its name")
        }
    }

    /// An install from BEFORE favorite trips existed: only the old tables, with real rows in them.
    func testUpgradeFromTheOldSchemaKeepsEveryExistingFavoriteAndTicket() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {   // the previous app version's store
            let old = try ModelContainer(for: Schema(versionedSchema: AppSchemaV1.self), configurations: [ModelConfiguration(schema: Schema(versionedSchema: AppSchemaV1.self), url: url)])
            let ctx = old.mainContext
            ctx.insert(FavoriteItem(kind: FavoriteKind.busRoute.rawValue, city: "City:Hsinchu", routeName: "HSZ0020", title: "20", subtitle: "新竹"))
            ctx.insert(FavoriteItem(kind: FavoriteKind.bikeStation.rawValue, city: "Hsinchu", routeName: "HSZ500", title: "新竹火車站", subtitle: "站前", lat: 24.80, lon: 120.97))
            ctx.insert(FavoriteItem(kind: FavoriteKind.busStop.rawValue, city: "City:Taipei", routeName: "TPE1", title: "台北車站", subtitle: "公車站"))
            try ctx.save()
        }

        // the new app version opens it through the migration plan
        let container = try AppStore.makeContainer(url: url)
        let ctx = container.mainContext
        let items = try ctx.fetch(FetchDescriptor<FavoriteItem>())
        XCTAssertEqual(items.count, 3, "no old favorite disappears")
        XCTAssertEqual(Set(items.map(\.kind)), [FavoriteKind.busRoute.rawValue, FavoriteKind.bikeStation.rawValue, FavoriteKind.busStop.rawValue])
        let bike = try XCTUnwrap(items.first { $0.kind == FavoriteKind.bikeStation.rawValue })
        XCTAssertEqual(bike.title, "新竹火車站"); XCTAssertEqual(bike.lat, 24.80, accuracy: 0.0001)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RailTicket>()).count, 0)

        // and the new tables work next to the old ones
        let store = TripStore(context: ctx)
        _ = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))
        XCTAssertEqual(store.favorites().count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FavoriteItem>()).count, 3, "adding a trip does not touch the old favorites")

        // a second launch after the upgrade
        let again = try AppStore.makeContainer(url: url)
        XCTAssertEqual(try again.mainContext.fetch(FetchDescriptor<FavoriteItem>()).count, 3)
        XCTAssertEqual(TripStore(context: again.mainContext).favorites().count, 1)
    }

    func testOldFavoritesStillSortIntoTheirOwnKinds() throws {
        let (_, container) = try makeStore()
        let ctx = container.mainContext
        ctx.insert(FavoriteItem(kind: FavoriteKind.busRoute.rawValue, city: "City:Taipei", routeName: "307", title: "307", subtitle: ""))
        ctx.insert(FavoriteItem(kind: "someFutureKind", city: "", routeName: "", title: "x", subtitle: ""))
        try ctx.save()
        // an unknown stored kind must not crash the grouping used by the favorites screen
        let items = try ctx.fetch(FetchDescriptor<FavoriteItem>())
        XCTAssertEqual(items.filter { (FavoriteKind(rawValue: $0.kind) ?? .busRoute) == .busRoute }.count, 2)
    }
}
