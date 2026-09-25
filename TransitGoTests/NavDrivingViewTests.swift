import XCTest
import CoreLocation
@testable import TransitGo

/// The pure rules behind the driving view: camera framing, where the dot is drawn, and camera (測速／科技執法) alerts.
final class NavDrivingViewTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 24.8393, longitude: 121.0093)
    private func offset(north: Double = 0, east: Double = 0, from origin: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D {
        LocalFrame(origin: origin ?? base).coordinate(x: east, y: north)
    }

    // MARK: camera framing

    func testDrivingViewIsTiltedAndLooksFurtherAtSpeed() {
        XCTAssertGreaterThan(NavCamera.pitch(driving: true), 45)          // was 15°: a flat view showed one block
        XCTAssertGreaterThan(NavCamera.pitch(driving: true), NavCamera.pitch(driving: false))
        XCTAssertEqual(NavCamera.distance(driving: true, speed: 0), 380, accuracy: 0.1)
        XCTAssertEqual(NavCamera.distance(driving: true, speed: 27.8), 658, accuracy: 1)   // 100 km/h
        XCTAssertEqual(NavCamera.distance(driving: true, speed: 80), 730, accuracy: 0.1)   // capped
        XCTAssertEqual(NavCamera.distance(driving: true, speed: -1), 380, accuracy: 0.1)   // no reading
        XCTAssertEqual(NavCamera.distance(driving: false, speed: 1.4), 200, accuracy: 0.1)
    }

    func testCameraAimsAheadOfTheUserByAFractionOfTheViewDistance() {
        XCTAssertEqual(NavCamera.lookAheadMeters(distance: 500), 160, accuracy: 0.1)
        XCTAssertLessThan(NavCamera.followAnimationSeconds, 0.35)   // the old default ease trailed the dot
    }

    // MARK: dot position

    func testRouteCoordinateAtAlongDistance() throws {
        // north 300 m, then east 400 m
        let a = offset(), b = offset(north: 300), c = offset(north: 300, east: 400)
        let track = try XCTUnwrap(RouteTrack(coordinates: [a, b, c]))
        let mid = track.coordinate(atAlong: 150)
        XCTAssertEqual(LocalFrame(origin: a).xy(mid).y, 150, accuracy: 1)
        let onSecond = track.coordinate(atAlong: 500)          // 200 m into the eastward leg
        XCTAssertEqual(LocalFrame(origin: a).xy(onSecond).x, 200, accuracy: 1)
        XCTAssertEqual(LocalFrame(origin: a).xy(onSecond).y, 300, accuracy: 1)
        let past = track.coordinate(atAlong: 9999)
        XCTAssertEqual(past.latitude, c.latitude, accuracy: 1e-9)
    }

    func testDotLeadsAStaleFixByWhatTheCarHasTravelled() {
        XCTAssertEqual(NavPosition.leadMeters(speed: 27.8, fixAge: 0.5), 13.9, accuracy: 0.1)
        XCTAssertEqual(NavPosition.leadMeters(speed: 27.8, fixAge: 10), 45, accuracy: 0.1)     // age and lead are capped
        XCTAssertEqual(NavPosition.leadMeters(speed: 0.5, fixAge: 1), 0)                       // standing still: no drift
        XCTAssertEqual(NavPosition.leadMeters(speed: -1, fixAge: 1), 0)                        // CoreLocation has no speed
        XCTAssertEqual(NavPosition.leadMeters(speed: 20, fixAge: -3), 0)                       // clock skew
    }

    func testDrivingSnapsFromFurtherAwayThanWalking() {
        XCTAssertEqual(NavPosition.snapTolerance(accuracy: 5, driving: true), 25)
        XCTAssertEqual(NavPosition.snapTolerance(accuracy: 30, driving: true), 40)             // capped
        XCTAssertEqual(NavPosition.snapTolerance(accuracy: 5, driving: false), 12)
    }

    // MARK: camera alert distance / side

    func testAlertComesEarlierAtHighwaySpeed() {
        XCTAssertEqual(SpeedCamPolicy.announceDistance(speed: 8), 300)        // town: never closer than 300 m
        XCTAssertEqual(SpeedCamPolicy.announceDistance(speed: 27.8), 556, accuracy: 1)   // 100 km/h ≈ 20 s
        XCTAssertEqual(SpeedCamPolicy.announceDistance(speed: 90), 1200)
        XCTAssertEqual(SpeedCamPolicy.announceDistance(speed: -1), 300)
    }

    func testOnlyCamerasAheadCount() {
        let ahead = offset(north: 400), behind = offset(north: -400), beside = offset(east: 300)
        XCTAssertTrue(SpeedCamPolicy.isAhead(user: base, cam: ahead, heading: 0))
        XCTAssertFalse(SpeedCamPolicy.isAhead(user: base, cam: behind, heading: 0))
        XCTAssertTrue(SpeedCamPolicy.isAhead(user: base, cam: behind, heading: 180))
        XCTAssertTrue(SpeedCamPolicy.isAhead(user: base, cam: offset(north: -10), heading: 0))     // GPS jitter range
        XCTAssertTrue(SpeedCamPolicy.isAhead(user: base, cam: behind, heading: nil))               // unknown heading: keep
        XCTAssertTrue(SpeedCamPolicy.isAhead(user: base, cam: beside, heading: 0))                  // 90° is still in view
    }

    // MARK: direction text from the real feeds (values seen in the national list, 國道 included)

    func testRealDirectionStrings() {
        let cases: [(String, Double?)] = [
            ("往南", 180), ("往北", 0), ("往東", 90), ("往西", 270),
            ("南向北", 0), ("北向南", 180), ("東向西", 270), ("西向東", 90),
            ("西南向東北", 45), ("東北向西南", 225), ("東南向西北", 315), ("西北向東南", 135),
            ("北向", 0), ("南向", 180), ("西向", 270), ("東向(區間測速)", 90), ("北向(區間測速)", 0),
            ("往北方向", 0), ("東往西", 270), ("北上", 0), ("南下", 180),
            // both ways / not a bearing → nil ("applies whichever way you drive")
            ("往南北", nil), ("南北", nil), ("往東西向", nil), ("雙向", nil), ("南北雙向", nil),
            ("南北雙向(區間測速)", nil), ("東西雙向(區間測速)", nil), ("快速路一段雙向", nil), ("往大溪方向", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SpeedCamPolicy.targetBearing(text), expected, "direction \(text)")
        }
    }

    func testBothWaysCameraIsNeverFilteredOut() {
        // "往南北" used to be read as south-only, silently dropping the alert for northbound traffic.
        XCTAssertTrue(SpeedCamPolicy.directionApplies("往南北", heading: 0))
        XCTAssertTrue(SpeedCamPolicy.directionApplies("往南北", heading: 180))
        XCTAssertTrue(SpeedCamPolicy.directionApplies(nil, heading: 90))
        XCTAssertTrue(SpeedCamPolicy.directionApplies("往南", heading: nil))
    }

    func testCameraFacingTheOtherCarriagewayIsFilteredOut() {
        XCTAssertTrue(SpeedCamPolicy.directionApplies("往南", heading: 170))
        XCTAssertFalse(SpeedCamPolicy.directionApplies("往南", heading: 0))
        XCTAssertTrue(SpeedCamPolicy.directionApplies("往北", heading: 350))
        XCTAssertFalse(SpeedCamPolicy.directionApplies("往北", heading: 180))
    }
}
