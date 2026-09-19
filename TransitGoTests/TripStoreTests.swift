import XCTest
import SwiftData
import CoreLocation
@testable import TransitGo

@MainActor
final class TripStoreTests: XCTestCase {

    // MARK: CRUD

    func testCreateReadUpdateDelete() throws {
        let (store, _) = try makeStore()
        let spec = TripSpec(origin: Place.home, destination: Place.school, profile: .fewestTransfers)
        let created = try store.addFavorite(spec: spec)
        XCTAssertEqual(created.name, "家 → 學校", "default name is built from the two places")
        XCTAssertEqual(created.useCount, 0); XCTAssertNil(created.lastUsedAt)

        // read: every field survives the flat-column round trip
        let read = try XCTUnwrap(store.favorite(id: created.id))
        XCTAssertEqual(read.spec, spec)
        XCTAssertEqual(read.spec.destination.kind, .poi)

        // update: rename, change destination + preference; history untouched
        try store.recordUse(read)
        try store.update(read, name: "上學", spec: TripSpec(origin: Place.home, destination: Place.taipeiMain, profile: .leastWalking))
        let updated = try XCTUnwrap(store.favorite(id: created.id))
        XCTAssertEqual(updated.name, "上學")
        XCTAssertEqual(updated.spec.destination.refId, "BL12")
        XCTAssertEqual(updated.spec.profile, .leastWalking)
        XCTAssertEqual(updated.useCount, 1, "editing never resets use history")
        XCTAssertEqual(store.favorites().count, 1, "editing never creates a second favorite")

        // blank name falls back to the default
        try store.update(updated, name: "   ")
        XCTAssertEqual(updated.name, "家 → 台北車站")

        // delete
        try store.delete(updated)
        XCTAssertTrue(store.favorites().isEmpty)
    }

    func testTheSameJourneyCannotBeSavedTwiceEvenWithDifferentNames() throws {
        let (store, _) = try makeStore()
        let first = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))
        var renamed = Place.school; renamed.name = "大學"   // display name is not identity
        XCTAssertThrowsError(try store.addFavorite(spec: TripSpec(origin: Place.home, destination: renamed))) { error in
            XCTAssertEqual(error as? TripStore.StoreError, .duplicate(first.id))
        }
        XCTAssertEqual(store.favorites().count, 1)
    }

    func testInvalidTripsAreRejected() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.home)), "same place")
        let zero = TripEndpoint(name: "空", kind: .address, latitude: 0, longitude: 0)
        XCTAssertThrowsError(try store.addFavorite(spec: TripSpec(origin: Place.home, destination: zero)), "0,0 is not a place")
        let abroad = TripEndpoint(name: "東京", kind: .poi, latitude: 35.68, longitude: 139.76)
        XCTAssertThrowsError(try store.addFavorite(spec: TripSpec(origin: Place.home, destination: abroad)), "outside Taiwan")
        XCTAssertThrowsError(try store.addFavorite(spec: TripSpec(origin: .currentLocation, destination: .currentLocation)))
        XCTAssertNoThrow(try store.addFavorite(spec: TripSpec(origin: .currentLocation, destination: Place.school)), "current location is a valid origin")
        XCTAssertEqual(store.favorites().count, 1)
    }

    func testEndpointIdentityIsNotTheDisplayName() {
        var a = Place.taipeiMain, b = Place.taipeiMain
        a.name = "北車"; b.name = "Taipei Main"
        XCTAssertEqual(a.key, b.key, "same station id -> same identity")
        var other = Place.taipeiMain; other.refId = "R10"
        XCTAssertNotEqual(a.key, other.key, "another station id -> different identity even with the same name")
        var moved = Place.home; moved.latitude += 0.01
        XCTAssertNotEqual(Place.home.key, moved.key)
    }

    // MARK: use counting + ordering

    func testUseCountAndOrdering() throws {
        let (store, _) = try makeStore()
        let a = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school), at: Date(timeIntervalSince1970: 100))
        let b = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.taipeiMain), at: Date(timeIntervalSince1970: 200))
        try store.recordUse(a, at: Date(timeIntervalSince1970: 1_000))
        try store.recordUse(a, at: Date(timeIntervalSince1970: 2_000))
        try store.recordUse(b, at: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(a.useCount, 2); XCTAssertEqual(a.lastUsedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.favorites(sortedBy: .recentlyUsed).map(\.id), [b.id, a.id])
        XCTAssertEqual(store.favorites(sortedBy: .mostUsed).map(\.id), [a.id, b.id])
    }

    // MARK: recents

    func testRecentsDeduplicateByPlaceAndCountSearches() throws {
        let (store, _) = try makeStore()
        var renamed = Place.school; renamed.name = "台大"
        try store.recordSearch(TripSpec(origin: Place.home, destination: Place.school), at: Date(timeIntervalSince1970: 100))
        try store.recordSearch(TripSpec(origin: Place.home, destination: renamed), at: Date(timeIntervalSince1970: 200))
        let recents = store.recents()
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents[0].searchCount, 2)
        XCTAssertEqual(recents[0].searchedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recents[0].destinationName, "台大", "the latest name is kept")
    }

    func testRecentsAreCappedAtTenNewestKept() throws {
        let (store, _) = try makeStore()
        for i in 0..<15 {
            let dest = TripEndpoint(name: "地點\(i)", kind: .poi, latitude: 25.0 + Double(i) * 0.01, longitude: 121.5)
            try store.recordSearch(TripSpec(origin: Place.home, destination: dest), at: Date(timeIntervalSince1970: Double(i)))
        }
        let recents = store.recents()
        XCTAssertEqual(recents.count, TripStore.maxRecents)
        XCTAssertEqual(recents.first?.destinationName, "地點14", "newest first")
        XCTAssertEqual(recents.last?.destinationName, "地點5", "the 5 oldest were dropped")
    }

    func testInvalidSearchesAreNotRemembered() throws {
        let (store, _) = try makeStore()
        try store.recordSearch(TripSpec(origin: Place.home, destination: Place.home))
        XCTAssertTrue(store.recents().isEmpty)
    }

    // MARK: suggestion

    func testSuggestionAfterThreeSearchesAndNeverAutomatic() throws {
        let (store, _) = try makeStore()
        let spec = TripSpec(origin: Place.home, destination: Place.school)
        try store.recordSearch(spec); try store.recordSearch(spec)
        XCTAssertNil(store.suggestion(), "two searches is not enough")
        try store.recordSearch(spec)
        let suggestion = try XCTUnwrap(store.suggestion())
        XCTAssertEqual(suggestion.spec.identity, spec.identity)
        XCTAssertTrue(store.favorites().isEmpty, "a suggestion never adds a favorite by itself")
    }

    func testSuggestionStopsOnceDismissedOrSaved() throws {
        let (store, _) = try makeStore()
        let spec = TripSpec(origin: Place.home, destination: Place.school)
        for _ in 0..<3 { try store.recordSearch(spec) }
        try store.dismissSuggestion(try XCTUnwrap(store.suggestion()))
        XCTAssertNil(store.suggestion(), "dismissed means never asked again")
        try store.recordSearch(spec)
        XCTAssertNil(store.suggestion())

        let other = TripSpec(origin: Place.home, destination: Place.taipei101)
        for _ in 0..<3 { try store.recordSearch(other) }
        XCTAssertNotNil(store.suggestion())
        try store.addFavorite(spec: other)
        XCTAssertNil(store.suggestion(), "already a favorite -> nothing to suggest")
    }

    // MARK: reverse

    func testReverseSwapsEndsAndKeepsPreference() {
        let spec = TripSpec(origin: Place.home, destination: Place.school, profile: .leastWalking)
        let back = spec.reversed
        XCTAssertEqual(back.origin, Place.school); XCTAssertEqual(back.destination, Place.home)
        XCTAssertEqual(back.profile, .leastWalking)
        XCTAssertEqual(back.reversed, spec, "⇅ twice is the original")
        XCTAssertNotEqual(spec.identity, back.identity, "A→B and B→A are different journeys")
    }

    func testPlannerViewModelReverseAndCurrentLocation() {
        let vm = TransferPlannerViewModel()
        let here = CLLocationCoordinate2D(latitude: 25.0400, longitude: 121.5200)
        vm.load(TripSpec(origin: .currentLocation, destination: Place.school), currentLocation: here)
        XCTAssertNil(vm.originOverride, "current location = no override")
        XCTAssertEqual(vm.currentSpec?.origin.kind, .currentLocation)
        vm.reverse(currentLocation: here)
        XCTAssertEqual(vm.originOverride?.name, "學校", "the old destination is now the origin")
        XCTAssertEqual(vm.destination?.kind, .currentLocation, "current location travels to the destination end")
        XCTAssertEqual(vm.destination?.coordinate.latitude, here.latitude)
        vm.reverse(currentLocation: here)
        XCTAssertNil(vm.originOverride)
        XCTAssertEqual(vm.destination?.name, "學校")
    }

    // MARK: profile

    func testLowestCostIsNotOfferedWithoutFareData() {
        XCTAssertFalse(TripProfile.lowestCost.isSelectable)
        XCTAssertTrue(TripProfile.lowestCost.title.contains("目前無完整票價資料"))
        XCTAssertEqual(TripProfile.allCases.filter(\.isSelectable), [.fastest, .balanced, .fewestTransfers, .leastWalking])
        XCTAssertEqual(TripProfile.fastest.engineLabel, "最快")
        XCTAssertEqual(TripProfile.leastWalking.engineLabel, "少走路")
    }

    // MARK: dates

    func testDateWording() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 12, minute: 0))!
        let today = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 7, minute: 32))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 18, minute: 5))!
        XCTAssertEqual(TripDateText.lastUsed(today, now: now), "上次使用：今天 07:32")
        XCTAssertEqual(TripDateText.lastUsed(yesterday, now: now), "上次使用：昨天 18:05")
        XCTAssertEqual(TripDateText.lastUsed(nil, now: now), "尚未使用")
        XCTAssertEqual(TripDateText.recent(now.addingTimeInterval(-600), now: now), "10 分鐘前")
        XCTAssertEqual(TripDateText.recent(yesterday, now: now), "昨天")
    }
}
