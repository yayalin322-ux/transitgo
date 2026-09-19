import XCTest
import SwiftData
import CoreLocation
@testable import TransitGo

/// Opening a saved journey plans it AGAIN from the two places — against the time of opening — through
/// the same `UnifiedRoutingService` shape the planner uses. Nothing here uses the network.
@MainActor
final class TripPlannerTests: XCTestCase {

    private struct Call { let origin: CLLocationCoordinate2D; let destination: CLLocationCoordinate2D; let when: Date; let city: BusCity }

    /// A fake planner that records how it was called and answers with `answer`.
    private final class Recorder {
        var calls: [Call] = []
        var answer: UnifiedRoutingService.Result
        init(_ answer: UnifiedRoutingService.Result) { self.answer = answer }
        lazy var plan: TripPlanner.PlanFunction = { [unowned self] city, _, o, d, when in
            self.calls.append(Call(origin: o, destination: d, when: when, city: city)); return self.answer
        }
    }

    func testFavoriteIsReplannedFromItsPlacesAtTheCurrentTimeEveryTime() async throws {
        let (store, _) = try makeStore()
        let fav = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))

        let morning = Date(timeIntervalSince1970: 1_790_000_000)          // "today 08:00"
        let nextDay = morning.addingTimeInterval(86_400)                   // "tomorrow 08:00"
        _ = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: .trtc, currentLocation: nil, now: morning, planFunction: recorder.plan)
        _ = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: .trtc, currentLocation: nil, now: nextDay, planFunction: recorder.plan)

        XCTAssertEqual(recorder.calls.count, 2, "one planning call per open — never a stored result")
        XCTAssertEqual(recorder.calls[0].when, morning); XCTAssertEqual(recorder.calls[1].when, nextDay)
        XCTAssertEqual(recorder.calls[0].origin.latitude, Place.home.latitude)
        XCTAssertEqual(recorder.calls[0].destination.longitude, Place.school.longitude)
    }

    func testDifferentTimesMayGiveDifferentRoutesAndTheFavoriteIsUntouched() async throws {
        let (store, _) = try makeStore()
        let fav = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))
        let before = fav.spec
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快", duration: 1500)]))
        let first = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        recorder.answer = makeResult(routes: [try makeRoute(id: "R001", label: "最快", duration: 2100), try makeRoute(id: "R002", label: "少轉乘")])
        let second = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        guard case .routes(let a, _) = first, case .routes(let b, _) = second else { return XCTFail("routes expected") }
        XCTAssertEqual(a.multimodalRoutes.first?.durationSeconds, 1500)
        XCTAssertEqual(b.multimodalRoutes.first?.durationSeconds, 2100)
        XCTAssertEqual(b.multimodalRoutes.count, 2)
        XCTAssertEqual(fav.spec, before, "planning never edits the saved journey")
        XCTAssertNil(fav.lastUsedAt); XCTAssertEqual(fav.useCount, 0, "planning alone is not a 'use' — the tap is")
    }

    func testPreferredProfileGoesFirstAndNothingIsDropped() async throws {
        let routes = [try makeRoute(id: "R001", label: "最快"), try makeRoute(id: "R002", label: "少轉乘"), try makeRoute(id: "R003", label: "少走路")]
        let recorder = Recorder(makeResult(routes: routes))
        let spec = TripSpec(origin: Place.home, destination: Place.school, profile: .leastWalking)
        let outcome = await TripPlanner.plan(spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        guard case .routes(let result, let preferred) = outcome else { return XCTFail("routes expected") }
        XCTAssertEqual(preferred, "R003")
        XCTAssertEqual(result.multimodalRoutes.map(\.id), ["R003", "R001", "R002"])
        XCTAssertEqual(result.routes.first?.multimodalRouteId, "R003", "the unified list is ordered the same way")
        XCTAssertEqual(result.multimodalRoutes.count, 3)
    }

    func testPreferenceThatTheEngineDidNotProduceKeepsTheEnginesOrder() async throws {
        // 少走路 saved, but this time the engine only produced 最快 — nothing is invented, order unchanged.
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))
        let outcome = await TripPlanner.plan(TripSpec(origin: Place.home, destination: Place.school, profile: .leastWalking), city: nil, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        guard case .routes(let result, let preferred) = outcome else { return XCTFail() }
        XCTAssertNil(preferred); XCTAssertEqual(result.multimodalRoutes.map(\.id), ["R001"])
        XCTAssertEqual(recorder.calls.first?.city, .taipei, "no region: only the legacy same-city bus planner uses this fallback")
    }

    // MARK: current location

    func testCurrentLocationOriginUsesTheDeviceLocation() async throws {
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))
        let here = CLLocationCoordinate2D(latitude: 25.0400, longitude: 121.5200)
        _ = await TripPlanner.plan(TripSpec(origin: .currentLocation, destination: Place.school), city: .taipei, metroOperator: nil, currentLocation: here, planFunction: recorder.plan)
        XCTAssertEqual(recorder.calls.first?.origin.latitude, here.latitude)
    }

    func testCurrentLocationWithoutALocationIsAClearOutcomeNotACrash() async {
        let recorder = Recorder(makeResult(routes: []))
        let outcome = await TripPlanner.plan(TripSpec(origin: .currentLocation, destination: Place.school), city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        guard case .locationUnavailable = outcome else { return XCTFail() }
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: realtime

    func testRealtimeIsQueriedFreshForEveryOpen() async throws {
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))
        var realtimeCalls = 0
        let realtime: TripPlanner.RealtimeFunction = { result in realtimeCalls += 1; var r = result; r.realtimeByRouteId["R001"] = .unavailable(.timeout); return r }
        for _ in 0..<2 {
            guard case .routes(let planned, _) = await TripPlanner.plan(TripSpec(origin: Place.home, destination: Place.school), city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan) else { return XCTFail() }
            let enriched = await TripPlanner.withRealtime(planned, realtime: realtime)
            XCTAssertNotNil(enriched.realtimeByRouteId["R001"])
        }
        XCTAssertEqual(realtimeCalls, 2, "each open asks the realtime service again")
    }

    func testRealtimeUnavailableStillShowsTheStaticRoute() async throws {
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))
        guard case .routes(let planned, _) = await TripPlanner.plan(TripSpec(origin: Place.home, destination: Place.school), city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan) else { return XCTFail() }
        let enriched = await TripPlanner.withRealtime(planned, realtime: { result in
            var r = result
            r.realtimeByRouteId = ["R001": .unavailable(.unavailable)]   // realtime failed
            return r
        })
        XCTAssertEqual(enriched.routes.count, 1, "the static route is still there")
        XCTAssertEqual(enriched.multimodalRoutes.first?.durationSeconds, 1800)
        XCTAssertNil(enriched.realtimeByRouteId["R001"]?.overlay)
    }

    // MARK: failures — none of them may remove a favorite

    func testFailuresAreExplainedAndNeverTouchTheFavorite() async throws {
        let (store, _) = try makeStore()
        let fav = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))

        func run(_ result: UnifiedRoutingService.Result) async -> TripPlanOutcome {
            await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: { _, _, _, _, _ in result })
        }

        var networkDown = UnifiedRoutingService.Result(); networkDown.multimodalStatus = .unreachable("offline")
        guard case .networkProblem = await run(networkDown) else { return XCTFail("network") }
        XCTAssertEqual(TripPlanOutcome.networkProblem.message, "目前無法連線到路線服務，請稍後再試（你的收藏不會受影響）")

        var busDown = UnifiedRoutingService.Result(); busDown.busHadNetworkError = true
        guard case .networkProblem = await run(busDown) else { return XCTFail("bus network") }

        var none = UnifiedRoutingService.Result(); none.multimodalStatus = .success([])
        let noRoute = await run(none)
        guard case .noRoute = noRoute else { return XCTFail("no route") }
        XCTAssertEqual(noRoute.message, "目前找不到可行路線")

        var noOrigin = UnifiedRoutingService.Result(); noOrigin.multimodalStatus = .serverError(code: "NO_ORIGIN_NEARBY", message: "x")
        guard case .endpointUnusable(.origin) = await run(noOrigin) else { return XCTFail("origin gone") }
        var noDest = UnifiedRoutingService.Result(); noDest.multimodalStatus = .serverError(code: "NO_DESTINATION_NEARBY", message: "x")
        guard case .endpointUnusable(.destination) = await run(noDest) else { return XCTFail("destination gone") }
        var same = UnifiedRoutingService.Result(); same.multimodalStatus = .serverError(code: "SAME_ORIGIN_DESTINATION", message: "x")
        guard case .sameLocation = await run(same) else { return XCTFail("same") }
        XCTAssertTrue(TripPlanOutcome.endpointUnusable(.origin).message?.contains("重新選擇") ?? false)

        // after every failure the favorite is exactly as saved
        XCTAssertEqual(store.favorites().count, 1)
        XCTAssertEqual(store.favorites().first?.spec, TripSpec(origin: Place.home, destination: Place.school))
    }

    func testCorruptedEndpointIsRefusedBeforeReachingTheRouter() async throws {
        let (store, _) = try makeStore()
        let fav = try store.addFavorite(spec: TripSpec(origin: Place.home, destination: Place.school))
        fav.destinationLat = 0; fav.destinationLon = 0       // a damaged record
        let recorder = Recorder(makeResult(routes: [try makeRoute(id: "R001", label: "最快")]))
        let outcome = await TripPlanner.plan(fav.spec, city: .taipei, metroOperator: nil, currentLocation: nil, planFunction: recorder.plan)
        guard case .endpointUnusable(.destination) = outcome else { return XCTFail() }
        XCTAssertTrue(recorder.calls.isEmpty, "never sends 0,0 to the router")
        XCTAssertEqual(store.favorites().count, 1, "and the favorite stays so it can be edited")
    }

    func testPlannerViewModelReportsNoRouteWithoutFailingTheTrip() async throws {
        // The screen's own mapping: no routes -> a notice, the loaded journey is still on the form.
        let vm = TransferPlannerViewModel()
        vm.load(TripSpec(origin: Place.home, destination: Place.school), currentLocation: Place.home.coordinate)
        let outcome = TripPlanner.outcome(from: { var r = UnifiedRoutingService.Result(); r.multimodalStatus = .success([]); return r }(), profile: vm.preferredProfile)
        vm.tripNotice = outcome
        XCTAssertEqual(vm.tripNotice?.message, "目前找不到可行路線")
        XCTAssertEqual(vm.currentSpec?.destination.name, "學校")
    }
}
