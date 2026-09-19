import XCTest
import CoreLocation
@testable import TransitGo

final class NavCoreTests: XCTestCase {

    // 1° latitude ≈ 110,540 m in LocalFrame, so 0.001° ≈ 110.5 m.
    private let base = CLLocationCoordinate2D(latitude: 24.8393, longitude: 121.0093)
    private func north(_ meters: Double, east: Double = 0) -> CLLocationCoordinate2D {
        let f = LocalFrame(origin: base)
        return f.coordinate(x: east, y: meters)
    }
    private func fix(_ c: CLLocationCoordinate2D, acc: Double = 5, speed: Double = 10, at t: Date) -> CLLocation {
        CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: acc, verticalAccuracy: 5, course: 0, speed: speed, timestamp: t)
    }

    // MARK: RouteTrack

    func testProjectionOntoTheMiddleOfALongSegmentIsOnTheRoute() throws {
        // Two points 1 km apart: a vertex-only distance would read ~500 m off at the midpoint.
        let track = try XCTUnwrap(RouteTrack(coordinates: [north(0), north(1000)]))
        let p = track.project(north(500, east: 20))
        XCTAssertEqual(p.distanceFromRoute, 20, accuracy: 0.5)
        XCTAssertEqual(p.alongMeters, 500, accuracy: 1)
        XCTAssertEqual(track.totalMeters, 1000, accuracy: 1)
        XCTAssertEqual(p.bearingDegrees, 0, accuracy: 0.5)   // heading north
    }

    func testRemainingMetersAreMeasuredAlongTheRoadNotAsTheCrowFlies() throws {
        // north 300 m, then east 400 m: crow-flies from start to end is 500 m, the road is 700 m.
        let track = try XCTUnwrap(RouteTrack(coordinates: [north(0), north(300), north(300, east: 400)]))
        XCTAssertEqual(track.totalMeters, 700, accuracy: 2)
        let p = track.project(north(300, east: 100))
        XCTAssertEqual(track.remainingMeters(fromAlong: p.alongMeters), 300, accuracy: 3)
    }

    func testSearchAheadDoesNotSnapBackOntoAnEarlierPartOfAnOutAndBackRoute() throws {
        // out 500 m north, then back south along the same road (a U-turn route).
        let track = try XCTUnwrap(RouteTrack(coordinates: [north(0), north(500), north(0, east: 8)]))
        let ahead = track.project(north(250, east: 6), after: 700)   // already on the way back
        XCTAssertGreaterThan(ahead.alongMeters, 700)
        XCTAssertNil(RouteTrack(coordinates: [north(0)]))
    }

    // MARK: GPS filter

    func testStaleAndInaccurateFixesAreRejected() {
        var f = NavLocationFilter()
        let now = Date()
        XCTAssertNil(f.process(fix(north(0), acc: -1, at: now), now: now), "negative accuracy = invalid")
        XCTAssertNil(f.process(fix(north(0), acc: 120, at: now), now: now), "far too inaccurate")
        XCTAssertNil(f.process(fix(north(0), at: now.addingTimeInterval(-20)), now: now), "20 s old")
        XCTAssertNotNil(f.process(fix(north(0), at: now), now: now))
    }

    func testAnImpossibleJumpFromAMediocreFixIsIgnoredButARealMoveIsAcceptedEventually() {
        var f = NavLocationFilter()
        let t0 = Date()
        _ = f.process(fix(north(0), at: t0), now: t0)
        var t = t0
        // three "teleports" of 800 m in one second on 30 m accuracy: noise
        for _ in 0..<3 {
            t = t.addingTimeInterval(1)
            XCTAssertNil(f.process(fix(north(800), acc: 30, at: t), now: t))
        }
        // the fourth in a row: we really are there (tunnel exit) → trusted
        t = t.addingTimeInterval(1)
        let accepted = f.process(fix(north(800), acc: 30, at: t), now: t)
        XCTAssertNotNil(accepted)
        XCTAssertEqual(LocalFrame(origin: base).xy(accepted!.coordinate).y, 800, accuracy: 1)
    }

    func testSmoothingReducesNoiseAlongAStraightDrive() {
        var f = NavLocationFilter()
        var t = Date()
        var rawErr = 0.0, filteredErr = 0.0, n = 0.0
        // 10 m/s north along x = 0, with deterministic ±15 m lateral noise
        let noise: [Double] = [12, -14, 9, -11, 15, -8, 13, -15, 10, -12, 14, -9, 11, -13, 8, -10]
        for i in 0..<noise.count {
            let c = north(Double(i) * 10, east: noise[i])
            let out = f.process(fix(c, acc: 15, speed: 10, at: t), now: t)
            if i >= 4, let out {
                rawErr += abs(noise[i]); filteredErr += abs(LocalFrame(origin: base).xy(out.coordinate).x); n += 1
            }
            t = t.addingTimeInterval(1)
        }
        XCTAssertLessThan(filteredErr / n, rawErr / n * 0.75, "filtered lateral error should be clearly smaller than raw")
    }

    func testFilterFollowsRealMovementWithoutLagging() {
        var f = NavLocationFilter()
        var t = Date()
        var last: CLLocation?
        for i in 0..<20 { last = f.process(fix(north(Double(i) * 20), acc: 5, speed: 20, at: t), now: t); t = t.addingTimeInterval(1) }
        // 72 km/h, good fixes: the filtered position must be within a few metres of the truth
        XCTAssertEqual(LocalFrame(origin: base).xy(last!.coordinate).y, 380, accuracy: 6)
    }

    // MARK: off route

    func testAWrongTurnOnAGoodFixIsNoticedWithinTwoFixes() {
        var d = OffRouteDetector()
        XCTAssertFalse(d.update(distanceFromRoute: 60, accuracy: 5, mode: .vehicle))    // first fix: suspicious only
        XCTAssertTrue(d.update(distanceFromRoute: 70, accuracy: 5, mode: .vehicle))     // second: off route
    }

    func testClearlyFarAwayOnAGoodFixIsOffRouteImmediately() {
        var d = OffRouteDetector()
        XCTAssertTrue(d.update(distanceFromRoute: 200, accuracy: 5, mode: .vehicle))
    }

    func testASingleNoiseBlipOnTheRightRoadDoesNotReroute() {
        var d = OffRouteDetector()
        XCTAssertFalse(d.update(distanceFromRoute: 45, accuracy: 10, mode: .vehicle))
        XCTAssertFalse(d.update(distanceFromRoute: 3, accuracy: 10, mode: .vehicle))    // back on the road: streak resets
        XCTAssertFalse(d.update(distanceFromRoute: 45, accuracy: 10, mode: .vehicle))
    }

    func testAPoorFixNeitherTriggersNorClearsAnything() {
        var d = OffRouteDetector()
        XCTAssertFalse(d.update(distanceFromRoute: 90, accuracy: 60, mode: .vehicle))
        XCTAssertFalse(d.update(distanceFromRoute: 90, accuracy: 60, mode: .vehicle))
    }

    func testThresholdFollowsAccuracyAndMode() {
        XCTAssertLessThan(OffRouteDetector.threshold(mode: .walking, accuracy: 5), OffRouteDetector.threshold(mode: .vehicle, accuracy: 5))
        XCTAssertLessThan(OffRouteDetector.threshold(mode: .vehicle, accuracy: 5), OffRouteDetector.threshold(mode: .vehicle, accuracy: 40))
        XCTAssertLessThanOrEqual(OffRouteDetector.threshold(mode: .vehicle, accuracy: 500), 70)
    }

    // MARK: remaining time

    func testRemainingTimeCountsDownWithProgress() {
        let quarter = NavETA.remainingSeconds(remainingMeters: 750, routeMeters: 1000, routeSeconds: 600, speed: nil, vehicle: true)
        let half = NavETA.remainingSeconds(remainingMeters: 500, routeMeters: 1000, routeSeconds: 600, speed: nil, vehicle: true)
        let done = NavETA.remainingSeconds(remainingMeters: 0, routeMeters: 1000, routeSeconds: 600, speed: nil, vehicle: true)
        XCTAssertEqual(quarter, 450, accuracy: 0.1)
        XCTAssertEqual(half, 300, accuracy: 0.1)
        XCTAssertEqual(done, 0, accuracy: 0.1)
    }

    func testLiveSpeedNudgesButNeverSwingsTheEstimate() {
        let planned = NavETA.remainingSeconds(remainingMeters: 5000, routeMeters: 10_000, routeSeconds: 1200, speed: nil, vehicle: true)   // 600
        let crawling = NavETA.remainingSeconds(remainingMeters: 5000, routeMeters: 10_000, routeSeconds: 1200, speed: 3, vehicle: true)
        let flying = NavETA.remainingSeconds(remainingMeters: 5000, routeMeters: 10_000, routeSeconds: 1200, speed: 40, vehicle: true)
        XCTAssertGreaterThan(crawling, planned); XCTAssertLessThan(crawling, planned * 1.31)
        XCTAssertLessThan(flying, planned);      XCTAssertGreaterThan(flying, planned * 0.84)
        XCTAssertEqual(NavETA.remainingSeconds(remainingMeters: 5000, routeMeters: 10_000, routeSeconds: 1200, speed: 3, vehicle: false), planned, accuracy: 0.1)
        XCTAssertEqual(NavETA.remainingSeconds(remainingMeters: 5, routeMeters: 0, routeSeconds: 0, speed: 5, vehicle: true), 0)
    }

    // MARK: voice pacing

    func testSpeechGateSpeaksWhenIdleAndDoesNotRepeatTheSameLine() {
        var g = SpeechGate()
        let t = Date()
        XCTAssertEqual(g.decide("前方100公尺右轉", priority: .normal, now: t), .speakNow)
        g.finished()
        XCTAssertEqual(g.decide("前方100公尺右轉", priority: .normal, now: t.addingTimeInterval(3)), .skip)
        XCTAssertEqual(g.decide("前方100公尺右轉", priority: .normal, now: t.addingTimeInterval(11)), .speakNow)
    }

    func testMoreImportantMessageInterruptsLessImportantOne() {
        var g = SpeechGate()
        let t = Date()
        XCTAssertEqual(g.decide("距離目的地還有500公尺", priority: .low, now: t), .speakNow)
        XCTAssertEqual(g.decide("已偏離路線，重新規劃路線中", priority: .high, now: t.addingTimeInterval(0.5)), .interruptThenSpeak)
    }

    func testLowPriorityNeverQueuesBehindAnythingAndNormalWaitsItsTurn() {
        var g = SpeechGate()
        let t = Date()
        XCTAssertEqual(g.decide("前方200公尺左轉", priority: .normal, now: t), .speakNow)
        XCTAssertEqual(g.decide("距離目的地還有200公尺", priority: .low, now: t.addingTimeInterval(0.4)), .skip)
        XCTAssertEqual(g.decide("前方50公尺右轉", priority: .normal, now: t.addingTimeInterval(0.6)), .queueLatest)
        g.finished()
        XCTAssertEqual(g.decide("距離目的地還有100公尺", priority: .low, now: t.addingTimeInterval(2)), .speakNow)
    }

    // MARK: whole-drive replay (filter → projection → off-route → ETA)

    /// Drives a 2 km route at 15 m/s with realistic GPS noise, then takes a wrong turn.
    func testDriveReplayNoFalseRerouteOnTheRightRoadButAWrongTurnIsCaughtQuickly() throws {
        let track = try XCTUnwrap(RouteTrack(coordinates: [north(0), north(1000), north(2000)]))
        var filter = NavLocationFilter()
        var detector = OffRouteDetector()
        var t = Date()
        var falseAlarms = 0
        var lastEta = Double.infinity
        var etaWentUp = 0
        var progress: RouteTrack.Projection?

        // deterministic noise, up to ±14 m lateral, ±8 m along, accuracy 8–14 m
        func noise(_ i: Int) -> (Double, Double, Double) {
            let a = sin(Double(i) * 1.7), b = cos(Double(i) * 2.3)
            return (a * 14, b * 8, 8 + abs(a) * 6)
        }
        // 1) 60 s on the right road
        for i in 0..<60 {
            let (lat, along, acc) = noise(i)
            let raw = fix(north(Double(i) * 15 + along, east: lat), acc: acc, speed: 15, at: t)
            if let f = filter.process(raw, now: t) {
                progress = track.project(f.coordinate, after: progress?.alongMeters)
                if detector.update(distanceFromRoute: progress!.distanceFromRoute, accuracy: f.horizontalAccuracy, mode: .vehicle) { falseAlarms += 1 }
                let eta = NavETA.remainingSeconds(remainingMeters: track.remainingMeters(fromAlong: progress!.alongMeters),
                                                  routeMeters: track.totalMeters, routeSeconds: 160, speed: f.speed, vehicle: true)
                if eta > lastEta + 2 { etaWentUp += 1 }   // may wiggle by noise, never jump up
                lastEta = eta
            }
            t = t.addingTimeInterval(1)
        }
        XCTAssertEqual(falseAlarms, 0, "GPS noise on the correct road must not trigger a reroute")
        XCTAssertEqual(etaWentUp, 0, "the countdown must keep counting down while making progress")
        // ~885 m of 2000 done → about 56 % of the 160 s plan should remain (≈ 89 s), not the full 160 s
        XCTAssertLessThan(lastEta, 160 * 0.6, "the remaining time must have dropped with progress")
        XCTAssertGreaterThan(lastEta, 160 * 0.4)

        // 2) wrong turn: leaves the road heading east at 15 m/s from 900 m along
        var fixesUntilAlarm: Int?
        for j in 1...8 {
            let raw = fix(north(900, east: Double(j) * 15), acc: 8, speed: 15, at: t)
            if let f = filter.process(raw, now: t) {
                progress = track.project(f.coordinate, after: progress?.alongMeters)
                if detector.update(distanceFromRoute: progress!.distanceFromRoute, accuracy: f.horizontalAccuracy, mode: .vehicle), fixesUntilAlarm == nil {
                    fixesUntilAlarm = j
                }
            }
            t = t.addingTimeInterval(1)
        }
        let n = try XCTUnwrap(fixesUntilAlarm, "a wrong turn must be detected")
        XCTAssertLessThanOrEqual(n, 4, "…within about four seconds of leaving the road")
    }
}
