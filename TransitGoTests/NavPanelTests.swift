import XCTest
@testable import TransitGo

final class NavPanelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDistanceIsRoundedToASensibleStep() {
        XCTAssertEqual(NavPanel.roundedDistance(43), 40)
        XCTAssertEqual(NavPanel.roundedDistance(147), 150)
        XCTAssertEqual(NavPanel.roundedDistance(212), 200)
        XCTAssertEqual(NavPanel.roundedDistance(478), 500)
        XCTAssertEqual(NavPanel.roundedDistance(1234), 1200)
        XCTAssertEqual(NavPanel.roundedDistance(-5), 0)
    }

    func testCountdownIsInMinutesWithSecondsOnlyAtTheEnd() {
        XCTAssertEqual(NavPanel.roundedETA(600), 600)
        XCTAssertEqual(NavPanel.roundedETA(601), 660, "rounded up: never claims less time than there is")
        XCTAssertEqual(NavPanel.roundedETA(200), 240)
        XCTAssertEqual(NavPanel.roundedETA(89), 90)
        XCTAssertEqual(NavPanel.roundedETA(43), 45)
        XCTAssertEqual(NavPanel.etaText(720), "12 分")
        XCTAssertEqual(NavPanel.etaText(4500), "1 小時 15 分")
        XCTAssertEqual(NavPanel.etaText(45), "45 秒")
        XCTAssertEqual(NavPanel.etaText(0), "即將抵達")
        XCTAssertEqual(NavPanel.distanceText(850), "850 公尺")
        XCTAssertEqual(NavPanel.distanceText(2300), "2.3 公里")
    }

    func testTheNumbersDoNotChangeMoreOftenThanEveryTwoSeconds() {
        var p = NavPanel()
        _ = p.update(distance: 1000, etaSeconds: 300, speed: 15, now: t0)
        var changes = 0
        var last = p.shown
        // 1 fix per second for 20 s at 15 m/s: raw distance falls 15 m every second
        for i in 1...20 {
            let now = t0.addingTimeInterval(Double(i))
            let s = p.update(distance: 1000 - 15 * Double(i), etaSeconds: 300 - Double(i), speed: 15, now: now)
            if s != last { changes += 1; last = s }
        }
        XCTAssertLessThanOrEqual(changes, 10, "at most one change per 2 s")
        XCTAssertGreaterThanOrEqual(changes, 1, "but it still moves")
    }

    func testARealJumpShowsAtOnce() {
        var p = NavPanel()
        _ = p.update(distance: 800, etaSeconds: 240, speed: 10, now: t0)
        let s = p.update(distance: 3000, etaSeconds: 600, speed: 10, now: t0.addingTimeInterval(0.5))   // wrong turn → new, longer route
        XCTAssertEqual(s?.distanceMeters, 3000, "no 2-second delay on a reroute-sized change")
    }

    func testForceShowsImmediatelyAndResetStartsFresh() {
        var p = NavPanel()
        _ = p.update(distance: 800, etaSeconds: 240, speed: 10, now: t0)
        XCTAssertEqual(p.update(distance: 760, etaSeconds: 230, speed: 10, now: t0.addingTimeInterval(0.3), force: true)?.distanceMeters, 750)
        p.reset()
        XCTAssertNil(p.shown)
        XCTAssertEqual(p.update(distance: 120, etaSeconds: 30, speed: nil, now: t0)?.distanceMeters, 120)
    }

    func testArrivingShowsAtOnce() {
        var p = NavPanel()
        _ = p.update(distance: 60, etaSeconds: 20, speed: 5, now: t0)
        XCTAssertEqual(p.update(distance: 25, etaSeconds: 8, speed: 3, now: t0.addingTimeInterval(0.2))?.distanceMeters, 30)
    }

    func testSpeedIsSmoothedNotJumpedAround() {
        var p = NavPanel()
        _ = p.update(distance: 900, etaSeconds: 200, speed: 10, now: t0)
        var shownSpeeds: [Int] = []
        for (i, v) in [10.0, 13.0, 9.0, 12.0, 10.5, 12.5, 9.5, 11.5].enumerated() {
            if let s = p.update(distance: 900 - Double(i) * 5, etaSeconds: 200, speed: v, now: t0.addingTimeInterval(Double(i + 1) * 2.1))?.speedKmh { shownSpeeds.append(s) }
        }
        let spread = (shownSpeeds.max() ?? 0) - (shownSpeeds.min() ?? 0)
        XCTAssertLessThan(spread, 12, "raw speed swings 9…13 m/s (32…47 km/h); the display should swing much less (\(shownSpeeds))")
    }

    func testNoDistanceMeansNothingChanges() {
        var p = NavPanel()
        XCTAssertNil(p.update(distance: nil, etaSeconds: 10, speed: 1, now: t0))
    }
}
