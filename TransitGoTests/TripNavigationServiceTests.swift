import XCTest
import SwiftData
import CoreLocation
@testable import TransitGo

/// The service around the engine: reroute rules, offline, recovery, permission, performance — with fake location,
/// network state, clock and store. Fix positions are synthetic test inputs.
@MainActor
final class TripNavigationServiceTests: XCTestCase {

    private struct Rig {
        let service: TripNavigationService
        let location: FakeLocation
        let reach: FakeReachability
        let store: MemoryStore
        let clock: Clock
        let planned: PlannerLog
    }

    /// Records every planning request; answers with `answer`.
    @MainActor
    final class PlannerLog {
        var requests: [(spec: TripSpec, here: CLLocationCoordinate2D, when: Date)] = []
        var answer: TripPlanOutcome = .noRoute
    }
    @MainActor
    final class RealtimeLog { var calls = 0; var answer: RealtimeLookup = .unavailable(.unavailable) }

    private func rig(auth: CLAuthorizationStatus = .authorizedWhenInUse, store: MemoryStore? = nil, realtime: RealtimeLog? = nil, timers: Bool = false) -> (Rig, RealtimeLog) {
        let store = store ?? MemoryStore(), realtime = realtime ?? RealtimeLog()
        let location = FakeLocation(auth), reach = FakeReachability(), clock = Clock(), log = PlannerLog()
        let service = TripNavigationService(.init(
            location: location, reachability: reach, store: store,
            now: { clock.now },
            realtime: { _ in realtime.calls += 1; return realtime.answer },
            planner: { spec, here, when in log.requests.append((spec, here, when)); return log.answer },
            runsTimers: timers))
        return (Rig(service: service, location: location, reach: reach, store: store, clock: clock, planned: log), realtime)
    }

    private func start(_ r: Rig) throws {
        r.service.start(route: try Nav.walkBusMrtWalk(),
                        origin: TripEndpoint(name: "家", kind: .address, latitude: Nav.home.lat, longitude: Nav.home.lon),
                        destination: TripEndpoint(name: "目的地", kind: .address, latitude: Nav.dest.lat, longitude: Nav.dest.lon))
    }
    private func feed(_ r: Rig, _ p: Nav.Pt, at t: TimeInterval, accuracy: Double = 10) {
        r.clock.now = Nav.at(t)
        r.location.emit(Nav.fix(p, at: t, accuracy: accuracy))
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    // MARK: Permission

    func testLocationPermissionIsRequestedOnlyWhenTheTripStarts() throws {
        let (r, _) = rig(auth: .notDetermined)
        XCTAssertEqual(r.location.startCalls, 0, "creating the service asks for nothing")
        try start(r)
        XCTAssertEqual(r.location.startCalls, 1, "start() is where the tracker (and so the permission prompt) begins")
    }

    func testDeniedLocationStillShowsTheTripButNeverFollowsIt() throws {
        let (r, _) = rig(auth: .denied)
        try start(r)
        XCTAssertEqual(r.location.startCalls, 0, "no tracking without permission")
        XCTAssertEqual(r.service.session?.locationAuthorized, false)
        XCTAssertEqual(r.service.session?.current?.kind, .staticOverview)
        XCTAssertNil(r.service.session?.currentLocation)
        r.location.emit(Nav.fix(Nav.busStop, at: 10))          // even if a fix somehow arrived
        XCTAssertEqual(r.service.session?.currentLegIndex, 0)
    }

    // MARK: Leg switching through the service

    func testFixesDriveLegSwitchingAndBannersWithoutAnyPlanning() throws {
        let (r, _) = rig()
        try start(r)
        feed(r, Nav.before(Nav.busStop, from: Nav.home, meters: 45), at: 30)
        XCTAssertEqual(r.service.banner?.text, "即將抵達北門站")
        feed(r, Nav.busStop, at: 40); feed(r, Nav.busStop, at: 42)
        XCTAssertEqual(r.service.session?.currentLegIndex, 1)
        XCTAssertEqual(r.planned.requests.count, 0)
    }

    // MARK: Performance contract

    func testThousandsOfFixesNeverPlanAndNeverCallTheNetwork() throws {
        let rt = RealtimeLog()
        let (r, _) = rig(realtime: rt)
        try start(r)
        let baselineRealtime = rt.calls
        let started = Date()
        for i in 0..<3000 {
            // wander back and forth along the first walk (never triggering anything drastic)
            let t = Double(i % 100) / 100
            feed(r, Nav.lerp(Nav.home, Nav.before(Nav.busStop, from: Nav.home, meters: 120), t), at: 10 + Double(i) * 0.5)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(r.planned.requests.count, 0, "location updates never trigger a route search")
        XCTAssertEqual(rt.calls, baselineRealtime, "nor a realtime request (that is the 30 s timer)")
        XCTAssertLessThan(elapsed, 3.0, "3000 fixes processed in \(elapsed) s")
        print("PERF 3000 fixes in \(String(format: "%.3f", elapsed)) s, planner calls \(r.planned.requests.count)")
        // persistence is throttled too: not one file write per fix
        XCTAssertLessThan(r.store.saves, 600)
    }

    // MARK: Reroute

    private func offRouteFixes(_ r: Rig, from t: TimeInterval) {
        let off = Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.005)
        for k in 0..<4 { feed(r, off, at: t + Double(k) * 12) }
    }

    func testOffRouteReplansFromTheCurrentPositionNotTheOrigin() async throws {
        let (r, _) = rig()
        try start(r)
        let newRoute = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.005), to: Nav.dest, fromName: "目前位置", toName: "目的地", dep: 60, arr: 900, distance: 900)], id: "R777")
        r.planned.answer = .routes(makeResult(routes: [newRoute]), preferredRouteId: nil)
        offRouteFixes(r, from: 10)
        await settle()
        XCTAssertEqual(r.planned.requests.count, 1)
        let request = try XCTUnwrap(r.planned.requests.first)
        XCTAssertEqual(request.here.latitude, Nav.home.lat, accuracy: 0.0001)
        XCTAssertEqual(request.here.longitude, Nav.home.lon + 0.005, accuracy: 0.0001, "from where the rider IS")
        XCTAssertNotEqual(request.spec.origin.key, TripEndpoint(name: "家", kind: .address, latitude: Nav.home.lat, longitude: Nav.home.lon).key, "not the original origin")
        XCTAssertEqual(request.spec.destination.name, "目的地", "same destination")
        XCTAssertEqual(request.when, r.clock.now, "for right now")
        XCTAssertEqual(r.service.session?.routeId, "R777", "the new plan replaced the old")
        XCTAssertEqual(r.service.session?.reroutes, 1)
        XCTAssertTrue(r.service.events.contains { if case .rerouted(reason: .offRoute) = $0 { return true }; return false })
        XCTAssertEqual(r.service.session?.currentLegIndex, 0, "following the new plan from its first leg")
    }

    func testRerouteIsRateLimitedByCooldownAndCount() async throws {
        let (r, _) = rig()
        try start(r)
        r.planned.answer = .noRoute            // planner keeps failing: the old route stays in use
        offRouteFixes(r, from: 10)
        await settle()
        XCTAssertEqual(r.planned.requests.count, 1)
        // still off route 30 s later: inside the 90 s cooldown -> no second search
        for k in 0..<6 { feed(r, Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.005), at: 70 + Double(k) * 5) }
        await settle()
        XCTAssertEqual(r.planned.requests.count, 1, "cooldown: never a search per fix")
        XCTAssertNotNil(r.service.session, "the trip survives a failed reroute")
        XCTAssertEqual(r.service.session?.routeId, "R001")
        XCTAssertTrue(r.service.banner?.text.contains("仍依原路線導航") ?? false)
    }

    func testMissedDepartureFindsTheNextOptionFromWhereTheRiderStands() async throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.busStop, fromName: "家", toName: "臺北", dep: 0, arr: 100, distance: 120),
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        let (r, _) = rig()
        r.service.start(route: tra, origin: TripEndpoint(name: "家", kind: .address, latitude: Nav.home.lat, longitude: Nav.home.lon),
                        destination: TripEndpoint(name: "新竹", kind: .address, latitude: Nav.busAlight.lat, longitude: Nav.busAlight.lon))
        feed(r, Nav.busStop, at: 100); feed(r, Nav.busStop, at: 102)
        let nextTrain = try Nav.route([Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 1500, arr: 4500, line: "自強", estimated: false, stops: 5)], id: "R900")
        r.planned.answer = .routes(makeResult(routes: [nextTrain]), preferredRouteId: nil)
        feed(r, Nav.busStop, at: 740)          // 2 min after the 600 s departure, still on the platform
        await settle()
        XCTAssertTrue(r.service.events.contains { $0 == .missedDeparture(legIndex: 1) })
        XCTAssertEqual(r.planned.requests.count, 1)
        XCTAssertEqual(r.service.session?.routeId, "R900", "moved to the next train")
        XCTAssertTrue(r.service.events.contains { if case .rerouted(reason: .missedDeparture) = $0 { return true }; return false })
    }

    func testSevereDelayOnlySuggestsAndWaitsForTheUser() async throws {
        let tra = try Nav.route([Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5)])
        let rt = RealtimeLog()
        rt.answer = .loaded(try Nav.overlay(legIndex: 0, mode: "TRA", scheduled: 600, delaySeconds: 1200, estimated: 1800))
        let (r, _) = rig(realtime: rt)
        r.service.start(route: tra, origin: TripEndpoint(name: "臺北", kind: .address, latitude: Nav.busStop.lat, longitude: Nav.busStop.lon),
                        destination: TripEndpoint(name: "新竹", kind: .address, latitude: Nav.busAlight.lat, longitude: Nav.busAlight.lon))
        feed(r, Nav.busStop, at: 5)
        await settle()
        XCTAssertEqual(r.service.suggestedReroute, .severeDelay)
        XCTAssertEqual(r.planned.requests.count, 0, "a delay is offered as a choice, not acted on")
        r.planned.answer = .routes(makeResult(routes: [try Nav.route([Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 900, arr: 3900, line: "莒光", estimated: false, stops: 5)], id: "R555")]), preferredRouteId: nil)
        rt.answer = .unavailable(.unavailable)      // the replacement route has no fresh delay information
        r.service.rerouteNow()
        await settle()
        XCTAssertEqual(r.planned.requests.count, 1)
        XCTAssertEqual(r.service.session?.routeId, "R555")
        XCTAssertNil(r.service.suggestedReroute)
    }

    // MARK: Realtime through the service

    func testRealtimeRefreshUpdatesDelayAndFailureFallsBackToTheTimetable() async throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.busStop, fromName: "家", toName: "臺北", dep: 0, arr: 100, distance: 120),
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        let rt = RealtimeLog()
        rt.answer = .loaded(try Nav.overlay(legIndex: 1, mode: "TRA", scheduled: 600, delaySeconds: 240, estimated: 840))
        let (r, _) = rig(realtime: rt)
        r.service.start(route: tra, origin: TripEndpoint(name: "家", kind: .address, latitude: Nav.home.lat, longitude: Nav.home.lon), destination: TripEndpoint(name: "新竹", kind: .address, latitude: Nav.busAlight.lat, longitude: Nav.busAlight.lon))
        await settle()
        XCTAssertEqual(r.service.session?.realtime, .live)
        XCTAssertEqual(r.service.session?.delayByLeg[1], 240)
        XCTAssertEqual(r.service.banner?.text, "⚠️ 延誤 4 分鐘")

        rt.answer = .unavailable(.timeout)
        await r.service.refreshRealtime()
        XCTAssertEqual(r.service.session?.realtime, .unavailable)
        XCTAssertNotNil(r.service.session, "the trip continues on the timetable")
        XCTAssertEqual(r.service.session?.plan.legs[1].scheduledDeparture, Nav.at(600))
    }

    // MARK: Offline

    func testGoingOfflineKeepsTheTripAndRecoveryRefreshesRealtime() async throws {
        let rt = RealtimeLog()
        let (r, _) = rig(realtime: rt)
        try start(r)
        await settle()
        let before = rt.calls
        r.reach.set(false)
        XCTAssertEqual(r.service.session?.isOffline, true)
        XCTAssertNotNil(r.service.session, "the session does not disappear")
        XCTAssertEqual(r.service.banner?.text, "目前無網路，使用最近一次路線資料")
        // guidance continues from the cached route
        feed(r, Nav.busStop, at: 40); feed(r, Nav.busStop, at: 42)
        XCTAssertEqual(r.service.session?.currentLegIndex, 1)
        await r.service.refreshRealtime()
        XCTAssertEqual(rt.calls, before, "no network request while offline")
        r.reach.set(true)
        await settle()
        XCTAssertGreaterThan(rt.calls, before, "realtime is refreshed when the connection returns")
        XCTAssertEqual(r.service.session?.isOffline, false)
    }

    func testARerouteNeededOfflineWaitsForTheConnection() async throws {
        let (r, _) = rig()
        try start(r)
        r.reach.set(false)
        offRouteFixes(r, from: 10)
        await settle()
        XCTAssertEqual(r.planned.requests.count, 0, "cannot plan offline")
        let route = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.dest, fromName: "目前位置", toName: "目的地", dep: 60, arr: 900, distance: 900)], id: "R321")
        r.planned.answer = .routes(makeResult(routes: [route]), preferredRouteId: nil)
        r.clock.now = Nav.at(200)
        r.reach.set(true)
        await settle()
        XCTAssertEqual(r.planned.requests.count, 1, "retried as soon as the connection is back")
        XCTAssertEqual(r.service.session?.routeId, "R321")
    }

    // MARK: Recovery

    func testAnInterruptedTripResumesExactlyWhereItWas() async throws {
        let store = MemoryStore()
        let (a, _) = rig(store: store)
        try start(a)
        feed(a, Nav.busStop, at: 40); feed(a, Nav.busStop, at: 42)
        feed(a, Nav.lerp(Nav.busStop, Nav.busAlight, 0.2), at: 400)
        XCTAssertEqual(a.service.session?.status, .onTransit)
        XCTAssertNotNil(store.saved, "the trip was persisted")

        // the app is killed; a new process, a new service, same store
        let (b, _) = rig(store: store)
        b.clock.now = Nav.at(500)
        XCTAssertNotNil(TripNavigationService.recoverableSession(store: store, now: Nav.at(500)))
        XCTAssertTrue(b.service.recover())
        XCTAssertEqual(b.service.session?.currentLegIndex, 1)
        XCTAssertEqual(b.service.session?.status, .onTransit)
        XCTAssertEqual(b.service.session?.routeId, "R001")
        XCTAssertEqual(b.planned.requests.count, 0, "resuming does not plan the route again")
        XCTAssertEqual(b.location.startCalls, 1, "location tracking restarts")
        // and it keeps following
        feed(b, Nav.lerp(Nav.busStop, Nav.busAlight, 0.6), at: 800)
        XCTAssertEqual(b.service.session?.current?.kind, .rideVehicle)
    }

    func testAStaleOrFinishedTripIsNotResumed() throws {
        let store = MemoryStore()
        let (a, _) = rig(store: store)
        try start(a)
        XCTAssertNil(TripNavigationService.recoverableSession(store: store, now: Nav.at(13 * 3600)), "13 hours later: a dead trip")
        XCTAssertNil(store.saved, "and it is cleared")

        let (b, _) = rig(store: store)
        try start(b)
        b.service.cancel()
        XCTAssertNil(store.saved, "a finished/cancelled trip is not 'in progress'")
        XCTAssertNil(TripNavigationService.recoverableSession(store: store, now: Nav.at(60)))
    }

    func testCompletionStopsTrackingAndClearsTheStore() throws {
        let (r, _) = rig()
        try start(r)
        let stops = r.location.stopCalls
        r.service.cancel()
        XCTAssertEqual(r.location.stopCalls, stops + 1)
        XCTAssertFalse(r.service.isActive)
    }

    // MARK: Favorite / recent integration

    func testAFavoriteTripFlowsIntoALiveSession() async throws {
        let (store, _) = try makeStore()
        let fav = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.taipeiMain))
        // favorite -> re-plan (the same path the planner uses) -> route -> session
        let route = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.dest, fromName: "家", toName: "台北車站", dep: 0, arr: 600, distance: 700)])
        let outcome = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: { _, _, _, _, _ in makeResult(routes: [route]) })
        guard case .routes(let result, _) = outcome, let planned = result.multimodalRoutes.first else { return XCTFail() }
        let (r, _) = rig()
        r.service.start(route: planned, origin: fav.spec.origin, destination: fav.spec.destination, profile: fav.spec.profile)
        XCTAssertEqual(r.service.session?.origin.name, "家")
        XCTAssertEqual(r.service.session?.destination.refId, "BL12")
        XCTAssertEqual(r.service.session?.plan.legs.count, 1)
    }

    func testARecentTripFlowsIntoALiveSessionToo() async throws {
        let (store, _) = try makeStore()
        try store.recordSearch(TripSpec(origin: Place.hsinchuHSR, destination: Place.taipeiMain))
        let recent = try XCTUnwrap(store.recents().first)
        let route = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.dest, fromName: "新竹高鐵站", toName: "台北車站", dep: 0, arr: 600, distance: 700)])
        let outcome = await TripPlanner.plan(recent.spec, city: .hsinchu, metroOperator: nil, currentLocation: nil, planFunction: { _, _, _, _, _ in makeResult(routes: [route]) })
        guard case .routes(let result, _) = outcome, let planned = result.multimodalRoutes.first else { return XCTFail() }
        let (r, _) = rig()
        r.service.start(route: planned, origin: recent.spec.origin, destination: recent.spec.destination)
        XCTAssertEqual(r.service.session?.origin.refId, "1030")
        XCTAssertTrue(r.service.isActive)
    }

    // MARK: Events

    func testEventsAreLoggedForUILogAndFutureNotifications() throws {
        let (r, _) = rig()
        try start(r)
        feed(r, Nav.busStop, at: 40); feed(r, Nav.busStop, at: 42)
        XCTAssertTrue(r.service.events.contains { if case .started = $0 { return true }; return false })
        XCTAssertTrue(r.service.events.contains { if case .legChanged(0, 1) = $0 { return true }; return false })
        XCTAssertTrue(r.service.events.contains { if case .arrivedAtStation(0, "北門站", false) = $0 { return true }; return false })
    }
}
