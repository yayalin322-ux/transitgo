import XCTest
import CoreLocation
@testable import TransitGo

/// Engine behaviour on deterministic sequences of fixes. The fixes are synthetic test inputs.
final class TripEngineTests: XCTestCase {
    typealias P = Nav.Pt

    private func engine(_ route: MultimodalRoute, authorized: Bool = true) -> TripEngine {
        var e = TripEngine(session: Nav.session(route, authorized: authorized))
        _ = e.begin(now: Nav.t0)
        return e
    }
    private func run(_ e: inout TripEngine, _ fixes: [(P, TimeInterval)], accuracy: Double = 10) -> [TripEvent] {
        fixes.flatMap { e.ingest(Nav.fix($0.0, at: $0.1, accuracy: accuracy), now: Nav.at($0.1)) }
    }
    private func has(_ events: [TripEvent], _ match: (TripEvent) -> Bool) -> Bool { events.contains(where: match) }

    // MARK: WALK

    func testWalkingLegShowsDistanceAndTimeThenApproachesAndArrives() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        XCTAssertEqual(e.session.status, .walkingToTransit)
        XCTAssertEqual(e.session.current?.kind, .walkTo)

        var events = run(&e, [(Nav.before(Nav.busStop, from: Nav.home, meters: 150), 20)])
        let cur = try XCTUnwrap(e.session.current)
        XCTAssertEqual(cur.distanceMeters ?? 0, 150, accuracy: 3)
        XCTAssertEqual(cur.durationSeconds ?? 0, Int(150 / 1.3), accuracy: 2, "walking time from the real remaining distance")
        XCTAssertEqual(cur.source, .gps)
        XCTAssertFalse(has(events) { if case .approachingStop = $0 { return true }; return false })

        events = run(&e, [(Nav.before(Nav.busStop, from: Nav.home, meters: 45), 60)])
        XCTAssertTrue(has(events) { if case .approachingStop(0, "北門站") = $0 { return true }; return false }, "即將抵達 at ~50 m")
        XCTAssertEqual(e.session.current?.kind, .approaching)
        XCTAssertEqual(e.session.currentLegIndex, 0, "not arrived yet")

        events = run(&e, [(Nav.before(Nav.busStop, from: Nav.home, meters: 12), 75), (Nav.before(Nav.busStop, from: Nav.home, meters: 8), 80)])
        XCTAssertTrue(has(events) { if case .legChanged(0, 1) = $0 { return true }; return false }, "leg switches by itself")
        XCTAssertEqual(e.session.currentLegIndex, 1)
        XCTAssertEqual(e.session.status, .waitingForTransit)
    }

    // MARK: ArrivalDetector behaviour (GPS noise)

    func testOneNoisyFixInsideTheRadiusIsNotArrival() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        // poor accuracy (60 m): one fix "at" the stop, then far again
        _ = e.ingest(Nav.fix(Nav.busStop, at: 30, accuracy: 60), now: Nav.at(30))
        XCTAssertEqual(e.session.currentLegIndex, 0, "a single low-accuracy fix does not arrive")
        _ = e.ingest(Nav.fix(Nav.before(Nav.busStop, from: Nav.home, meters: 120), at: 32, accuracy: 10), now: Nav.at(32))
        _ = e.ingest(Nav.fix(Nav.busStop, at: 34, accuracy: 60), now: Nav.at(34))
        XCTAssertEqual(e.session.currentLegIndex, 0, "the streak was broken by the fix in between")
        _ = e.ingest(Nav.fix(Nav.busStop, at: 36, accuracy: 60), now: Nav.at(36))
        XCTAssertEqual(e.session.currentLegIndex, 1, "two consecutive fixes inside the radius = arrived")
    }

    func testUnusableFixesAreIgnoredForDecisions() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        _ = e.ingest(Nav.fix(Nav.busStop, at: 30, accuracy: 500), now: Nav.at(30))
        _ = e.ingest(Nav.fix(Nav.busStop, at: 31, accuracy: -1), now: Nav.at(31))
        XCTAssertEqual(e.session.currentLegIndex, 0)
        XCTAssertNotNil(e.session.currentLocation, "still recorded as the last real fix, but not trusted")
    }

    func testOneVeryAccurateFixNearTheTargetIsEnough() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        _ = e.ingest(Nav.fix(Nav.before(Nav.busStop, from: Nav.home, meters: 5), at: 30, accuracy: 6), now: Nav.at(30))
        XCTAssertEqual(e.session.currentLegIndex, 1)
    }

    // MARK: BUS

    private func atBusStop(_ e: inout TripEngine) {
        _ = run(&e, [(Nav.busStop, 100), (Nav.busStop, 102)])
    }

    func testBusWaitingThenBoardedThenRideProgressAndStops() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        atBusStop(&e)
        XCTAssertEqual(e.session.status, .waitingForTransit)
        let wait = try XCTUnwrap(e.session.current)
        XCTAssertEqual(wait.kind, .waitForVehicle); XCTAssertEqual(wait.lineLabel, "182")
        XCTAssertEqual(wait.source, .estimate, "a headway bus has no timetable: the time is an estimate and says so")
        XCTAssertEqual(wait.time, Nav.at(300))

        // still at the stop before departure: not boarded
        XCTAssertFalse(has(run(&e, [(Nav.busStop, 200)])) { if case .boarded = $0 { return true }; return false })
        // 300 m away, past departure time: boarded
        let events = run(&e, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.1), 340)])
        XCTAssertTrue(has(events) { if case .boarded(1, false) = $0 { return true }; return false })
        XCTAssertEqual(e.session.status, .onTransit)

        // half way
        _ = run(&e, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.5), 700)])
        let mid = try XCTUnwrap(e.session.current)
        XCTAssertEqual(mid.kind, .rideVehicle)
        XCTAssertEqual(mid.stopsRemaining, 4, "8 stops, halfway by GPS")
        XCTAssertTrue(mid.stopsAreEstimated)
        XCTAssertEqual(mid.source, .gps)
    }

    func testTransferWarningComesBeforeAlightingNotAfter() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        atBusStop(&e)
        _ = run(&e, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.1), 340)])
        // 400 m before the alight stop, still on the bus
        let events = run(&e, [(Nav.before(Nav.busAlight, from: Nav.busStop, meters: 400), 1000)])
        XCTAssertTrue(has(events) { if case .approachingStop(1, "台北車站(公車)") = $0 { return true }; return false })
        XCTAssertTrue(has(events) { if case .transferRequired(1, 3, "板南線") = $0 { return true }; return false }, "下一站轉乘 板南線 — before getting off")
        XCTAssertEqual(e.session.currentLegIndex, 1, "still on the bus")
        XCTAssertEqual(e.session.current?.kind, .prepareToAlight)
        XCTAssertEqual(e.session.nextTransfer?.lineLabel, "板南線")
        XCTAssertEqual(e.session.nextTransfer?.atName, "台北車站(捷運)")
        // and each notice is given once
        let again = run(&e, [(Nav.before(Nav.busAlight, from: Nav.busStop, meters: 300), 1020)])
        XCTAssertFalse(has(again) { if case .transferRequired = $0 { return true }; return false })
    }

    func testAlightingSwitchesToTheTransferWalk() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        atBusStop(&e)
        _ = run(&e, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.1), 340), (Nav.busAlight, 1180), (Nav.busAlight, 1182)])
        XCTAssertEqual(e.session.currentLegIndex, 2)
        XCTAssertEqual(e.session.status, .transferring, "walking between two vehicle legs")
        XCTAssertEqual(e.session.current?.targetName, "台北車站(捷運)")
    }

    // MARK: MRT (no GPS underground)

    func testMetroRideFollowsTheTimetableWhenGPSDisappears() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        // jump to the MRT leg: bus done, walk done, waiting at the station
        e = TripEngine(session: { var s = Nav.session(try! Nav.walkBusMrtWalk()); s.currentLegIndex = 3; s.legEnteredAt = Nav.at(1260); return s }())
        _ = e.begin(now: Nav.at(1260))
        _ = e.ingest(Nav.fix(Nav.mrtStation, at: 1270), now: Nav.at(1270))
        XCTAssertEqual(e.session.status, .waitingForTransit)
        // platform: no fix for > 90 s and departure time passed: on board (inferred)
        var events = e.tick(now: Nav.at(1470))
        XCTAssertTrue(has(events) { if case .boarded(3, true) = $0 { return true }; return false }, "inferred, and marked as such")
        XCTAssertTrue(e.session.boardedWasInferred)
        XCTAssertEqual(e.session.status, .onTransit)

        // mid ride: current/next stop names estimated from time, remaining stops estimated
        events = e.tick(now: Nav.at(1470 + 300))
        let cur = try XCTUnwrap(e.session.current)
        XCTAssertEqual(cur.source, .schedule)
        XCTAssertNotNil(cur.currentStopName); XCTAssertNotNil(cur.nextStopName)
        XCTAssertTrue(cur.stopsAreEstimated)
        // near the end: the alight warning, then arrival by the clock
        events = e.tick(now: Nav.at(1470 + 600 - 60))
        XCTAssertTrue(has(events) { if case .approachingStop(3, "南京復興") = $0 { return true }; return false })
        events = e.tick(now: Nav.at(1470 + 600 + 70))
        XCTAssertTrue(has(events) { if case .arrivedAtStation(3, "南京復興", true) = $0 { return true }; return false }, "arrival by schedule is flagged as inferred")
        XCTAssertEqual(e.session.currentLegIndex, 4)
    }

    func testClockDoesNotAdvanceARideWhileGPSSaysTheRiderIsStillFarAway() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        atBusStop(&e)
        _ = run(&e, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.1), 340)])
        // time is far past the scheduled arrival but the rider is 2 km from the alight stop (bus stuck in traffic)
        _ = run(&e, [(Nav.before(Nav.busAlight, from: Nav.busStop, meters: 2000), 2000)])
        XCTAssertEqual(e.session.currentLegIndex, 1, "GPS overrides the timetable")
    }

    // MARK: Transfer walk inside a station

    func testInStationInterchangeRunsOnItsPublishedMinutes() throws {
        let route = try Nav.route([
            Nav.Seg(mode: "MRT", from: Nav.mrtStation, to: Nav.mrtAlight, fromName: "A站", toName: "B站", dep: 0, arr: 600, line: "板南線", stops: 4),
            Nav.Seg(mode: "WALK", from: Nav.mrtAlight, to: Nav.mrtAlight, fromName: "B站", toName: "B站", dep: 600, arr: 840, walkKind: "MRT_TRANSFER_WALK"),
            Nav.Seg(mode: "MRT", from: Nav.mrtAlight, to: Nav.dest, fromName: "B站", toName: "C站", dep: 900, arr: 1200, line: "文湖線", stops: 3),
        ])
        var e = TripEngine(session: { var s = Nav.session(route); s.currentLegIndex = 1; s.legEnteredAt = Nav.at(600); return s }())
        _ = e.begin(now: Nav.at(600))
        XCTAssertEqual(e.session.status, .transferring)
        XCTAssertTrue(e.tick(now: Nav.at(700)).isEmpty, "still inside the 4-minute interchange")
        let events = e.tick(now: Nav.at(600 + 240 + 31))
        XCTAssertTrue(has(events) { if case .legChanged(1, 2) = $0 { return true }; return false })
        XCTAssertEqual(e.session.current?.lineLabel, "文湖線")
    }

    // MARK: BIKE / multimodal

    func testWalkBikeMetroWalkSwitchesEveryLegByItself() throws {
        let dock1 = Nav.Pt(lat: 25.0335, lon: 121.5436), dock2 = Nav.Pt(lat: 25.0460, lon: 121.5250)
        let station = Nav.Pt(lat: 25.0472, lon: 121.5252), out = Nav.Pt(lat: 25.0521, lon: 121.5436)   // ~130 m from the return dock
        let route = try Nav.route([
            Nav.Seg(mode: "WALK", from: Nav.home, to: dock1, fromName: "家", toName: "YouBike A", dep: 0, arr: 60, distance: 60),
            Nav.Seg(mode: "BIKE", from: dock1, to: dock2, fromName: "YouBike A", toName: "YouBike B", dep: 60, arr: 600, line: "YouBike", stops: 1, distance: 2400),
            Nav.Seg(mode: "WALK", from: dock2, to: station, fromName: "YouBike B", toName: "捷運站", dep: 600, arr: 640, distance: 55),
            Nav.Seg(mode: "MRT", from: station, to: out, fromName: "捷運站", toName: "南京復興", dep: 700, arr: 1200, line: "板南線", stops: 4),
            Nav.Seg(mode: "WALK", from: out, to: Nav.dest, fromName: "南京復興", toName: "目的地", dep: 1200, arr: 1280, distance: 100),
        ])
        var e = engine(route)
        XCTAssertEqual(e.session.status, .walkingToTransit)
        // walk to the dock
        _ = run(&e, [(Nav.before(dock1, from: Nav.home, meters: 30), 20), (dock1, 40), (dock1, 42)])
        XCTAssertEqual(e.session.currentLegIndex, 1)
        XCTAssertEqual(e.session.current?.kind, .rentBike, "at the dock: rent first")
        // ride off
        var events = run(&e, [(Nav.lerp(dock1, dock2, 0.2), 120)])
        XCTAssertTrue(has(events) { if case .boarded(1, false) = $0 { return true }; return false })
        XCTAssertEqual(e.session.status, .ridingBike)
        XCTAssertEqual(e.session.current?.kind, .rideBike)
        // near the return dock
        _ = run(&e, [(Nav.before(dock2, from: dock1, meters: 60), 500)])
        XCTAssertEqual(e.session.current?.kind, .returnBike)
        events = run(&e, [(dock2, 560), (dock2, 562)])
        XCTAssertEqual(e.session.currentLegIndex, 2)
        XCTAssertEqual(e.session.status, .walkingToTransit, "after the dock, the walk to the metro station")
        // station, board underground (no GPS), ride, arrive, final walk
        _ = run(&e, [(station, 630), (station, 632)])
        XCTAssertEqual(e.session.currentLegIndex, 3)
        _ = e.tick(now: Nav.at(900))       // > 90 s without a fix past departure
        XCTAssertEqual(e.session.status, .onTransit)
        _ = e.tick(now: Nav.at(1500))       // boarded ~900 + the 500 s ride + 60 s grace
        XCTAssertEqual(e.session.currentLegIndex, 4)
        XCTAssertEqual(e.session.status, .walkingToDestination)
        events = run(&e, [(Nav.dest, 1530), (Nav.dest, 1532)])
        XCTAssertTrue(has(events) { $0 == .completed })
        XCTAssertEqual(e.session.status, .arrived)
        XCTAssertEqual(e.session.progress, 1)
    }

    func testBikeLegIsNotArrivedWhileStillAtTheRentalDock() throws {
        let dock1 = Nav.Pt(lat: 25.0335, lon: 121.5436), dock2 = Nav.Pt(lat: 25.0460, lon: 121.5250)
        let route = try Nav.route([
            Nav.Seg(mode: "BIKE", from: dock1, to: dock2, fromName: "A", toName: "B", dep: 0, arr: 600, line: "YouBike", distance: 2400),
        ])
        var e = engine(route)
        XCTAssertEqual(e.session.current?.kind, .rentBike)
        _ = run(&e, [(dock1, 10), (dock1, 30), (dock1, 50)])   // standing at the rental dock
        XCTAssertEqual(e.session.currentLegIndex, 0)
        XCTAssertNil(e.session.boardedAt, "not riding until the rider has actually left the dock")
        XCTAssertEqual(e.session.current?.kind, .rentBike)
    }

    // MARK: Realtime

    func testRealtimeDelayIsShownAndTheScheduleIsUntouched() throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.busStop, fromName: "家", toName: "臺北", dep: 0, arr: 100, distance: 120),
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        var e = engine(tra)
        let events = e.apply(overlay: try Nav.overlay(legIndex: 1, mode: "TRA", scheduled: 600, delaySeconds: 300, estimated: 900), now: Nav.at(50))
        XCTAssertTrue(has(events) { if case .delayed(1, 300) = $0 { return true }; return false })
        XCTAssertEqual(e.session.realtime, .live)
        XCTAssertEqual(e.session.delayByLeg[1], 300)
        XCTAssertEqual(e.session.plan.legs[1].scheduledDeparture, Nav.at(600), "the timetable time is never overwritten")
        XCTAssertEqual(e.session.nextAction?.time, Nav.at(900), "departure shows scheduled + delay")
        XCTAssertEqual(e.session.nextAction?.delaySeconds, 300)
        XCTAssertEqual(e.session.nextAction?.source, .realtime)
        XCTAssertEqual(TripInstructionText.details(e.session.nextAction!).last, "⚠️ 延誤 5 分鐘")
    }

    func testRealtimeUnavailableFallsBackToTheTimetableAndSaysSo() throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        var e = engine(tra)
        _ = e.apply(overlay: try Nav.overlay(legIndex: 0, mode: "TRA", scheduled: 600, delaySeconds: 300, estimated: 900), now: Nav.at(10))
        let events = e.realtimeFailed(now: Nav.at(40))
        XCTAssertEqual(events, [.realtimeUnavailable])
        XCTAssertEqual(e.session.realtime, .unavailable)
        XCTAssertEqual(e.session.current?.source, .schedule, "依時刻表")
        XCTAssertEqual(e.realtimeFailedAgain(), [], "the notice is given once")
    }

    func testSevereDelayAndCancellationOnlySuggestRerouting() throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        var e = engine(tra)
        var events = e.apply(overlay: try Nav.overlay(legIndex: 0, mode: "TRA", scheduled: 600, delaySeconds: 1200, estimated: 1800), now: Nav.at(10))
        XCTAssertTrue(has(events) { $0 == .rerouteSuggested(reason: .severeDelay) })
        events = e.apply(overlay: try Nav.overlay(legIndex: 0, mode: "TRA", scheduled: 600, delaySeconds: nil, estimated: nil, state: "cancelled"), now: Nav.at(20))
        XCTAssertTrue(has(events) { $0 == .rerouteSuggested(reason: .cancelled) })
    }

    func testHeadwayVehicleUsesRealtimeEtaAsItsDeparture() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        _ = e.apply(overlay: try Nav.overlay(legIndex: 1, mode: "BUS", scheduled: 300, delaySeconds: nil, estimated: 420, state: "normal"), now: Nav.at(10))
        XCTAssertEqual(e.session.nextAction?.time, Nav.at(420))
        XCTAssertEqual(e.session.nextAction?.source, .realtime)
        XCTAssertNil(e.session.delayByLeg[1], "a headway bus has no timetable, so no 'delay' is invented")
    }

    // MARK: Missed departure

    func testMissedTimetabledDepartureIsDetectedOnceAndNeverForHeadwayLegs() throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 600, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        var e = engine(tra)
        XCTAssertTrue(run(&e, [(Nav.busStop, 500)]).isEmpty)
        var events = run(&e, [(Nav.busStop, 600 + 130)])
        XCTAssertTrue(has(events) { $0 == .missedDeparture(legIndex: 0) }, "still on the platform 2 min after the departure")
        events = run(&e, [(Nav.busStop, 800)])
        XCTAssertFalse(has(events) { if case .missedDeparture = $0 { return true }; return false }, "reported once")

        // a headway bus: waiting past its 'estimated' departure is not a miss
        var b = engine(try Nav.walkBusMrtWalk())
        _ = run(&b, [(Nav.busStop, 100), (Nav.busStop, 102)])
        XCTAssertFalse(has(run(&b, [(Nav.busStop, 900)])) { if case .missedDeparture = $0 { return true }; return false })
    }

    func testAMissIsPredictedWhileStillWalkingToTheStation() throws {
        let tra = try Nav.route([
            Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.busStop, fromName: "家", toName: "臺北", dep: 0, arr: 100, distance: 120),
            Nav.Seg(mode: "TRA", from: Nav.busStop, to: Nav.busAlight, fromName: "臺北", toName: "新竹", dep: 400, arr: 3600, line: "自強", estimated: false, stops: 5),
        ])
        var e = engine(tra)
        // 195 m from the station at t=390: needs 150 s more to walk, the train leaves at 400
        let events = e.ingest(Nav.fix(Nav.before(Nav.busStop, from: Nav.home, meters: 195), at: 390), now: Nav.at(390))
        XCTAssertTrue(has(events) { $0 == .missedDeparture(legIndex: 1) })
    }

    // MARK: Off route

    func testOffRouteNeedsSeveralFixesOverTimeAndReportsOnce() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        let off = Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.005)     // ~480 m east of the walking line
        XCTAssertTrue(run(&e, [(off, 10)]).isEmpty, "one outlier fix is not off-route")
        _ = run(&e, [(Nav.lerp(Nav.home, Nav.busStop, 0.3), 15)])           // back on the line: streak resets
        var events = run(&e, [(off, 20), (off, 30)])
        XCTAssertFalse(has(events) { if case .offRoute = $0 { return true }; return false }, "two fixes are still not enough")
        events = run(&e, [(off, 45)])
        XCTAssertTrue(has(events) { if case .offRoute(0, _) = $0 { return true }; return false })
        XCTAssertTrue(e.isOffRoute)
        XCTAssertFalse(has(run(&e, [(off, 60), (off, 70)])) { if case .offRoute = $0 { return true }; return false }, "reported once")
    }

    func testOffRouteThresholdsDependOnTheLegKind() throws {
        // 300 m from the line: off route for a walk (200 m) but normal for a bus ride (>= 1.5 km)
        var w = engine(try Nav.walkBusMrtWalk())
        let near = Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.0032)   // ~310 m
        XCTAssertTrue(has(run(&w, [(near, 10), (near, 25), (near, 40)])) { if case .offRoute = $0 { return true }; return false })

        var b = engine(try Nav.walkBusMrtWalk())
        atBusStop(&b)
        _ = run(&b, [(Nav.lerp(Nav.busStop, Nav.busAlight, 0.1), 340)])
        let side = Nav.lerp(Nav.busStop, Nav.busAlight, 0.5); let sideOff = Nav.Pt(lat: side.lat, lon: side.lon + 0.0032)
        XCTAssertFalse(has(run(&b, [(sideOff, 500), (sideOff, 520), (sideOff, 540)])) { if case .offRoute = $0 { return true }; return false })
    }

    func testPoorAccuracyFixesNeverTriggerOffRoute() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        let off = Nav.Pt(lat: Nav.home.lat, lon: Nav.home.lon + 0.005)
        let events = run(&e, [(off, 10), (off, 25), (off, 45), (off, 60)], accuracy: 90)
        XCTAssertFalse(has(events) { if case .offRoute = $0 { return true }; return false })
    }

    // MARK: No location permission

    func testWithoutLocationTheTripIsReadableButNeverFollowed() throws {
        var e = engine(try Nav.walkBusMrtWalk(), authorized: false)
        XCTAssertEqual(e.session.current?.kind, .staticOverview)
        XCTAssertNil(e.session.currentLocation, "no location is invented")
        let events = run(&e, [(Nav.busStop, 100), (Nav.busStop, 102), (Nav.mrtAlight, 3000)])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(e.session.currentLegIndex, 0, "cannot switch legs without knowing where the rider is")
        XCTAssertNotNil(e.session.remainingDurationSeconds)
    }

    // MARK: Remaining time / progress

    func testRemainingTimeAndProgressShrinkAsTheTripProgresses() throws {
        var e = engine(try Nav.walkBusMrtWalk())
        let start = try XCTUnwrap(e.session.remainingDurationSeconds)
        XCTAssertGreaterThan(start, 1500)
        _ = run(&e, [(Nav.busStop, 100), (Nav.busStop, 102)])
        let later = try XCTUnwrap(e.session.remainingDurationSeconds)
        XCTAssertLessThan(later, start)
        XCTAssertGreaterThan(e.session.progress, 0)
    }

    func testPolicyValuesAreSane() {
        XCTAssertLessThanOrEqual(TripPolicy.approachingWalkDistance, 50)
        XCTAssertGreaterThan(TripPolicy.offRouteWalk, TripPolicy.destinationRadius)
        XCTAssertGreaterThanOrEqual(TripPolicy.arrivalConfirmations, 2)
        XCTAssertGreaterThan(TripPolicy.offRouteVehicleFloor, TripPolicy.offRouteBike)
    }
}

private extension TripEngine {
    mutating func realtimeFailedAgain() -> [TripEvent] { realtimeFailed(now: Nav.at(50)) }
}
