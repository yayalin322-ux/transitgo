import XCTest
import CoreLocation
@testable import TransitGo

final class NavVoiceTests: XCTestCase {

    func testEveryModeKeepsTheSafetyAlertsExceptMuted() {
        for mode in VoiceMode.allCases where mode != .muted {
            for kind in [AnnouncementKind.offRoute, .reroute, .arrival, .camera] {
                XCTAssertTrue(mode.allows(kind), "\(mode) must still speak \(kind)")
            }
        }
        for kind in [AnnouncementKind.offRoute, .camera, .farManeuver, .nowManeuver, .milestone] {
            XCTAssertFalse(VoiceMode.muted.allows(kind))
        }
    }

    func testModesAreOrderedByHowMuchTheySay() {
        let kinds: [AnnouncementKind] = [.start, .farManeuver, .nowManeuver, .laneCue, .straightReminder, .milestone, .waypoint, .offRoute, .reroute, .arrival, .camera, .parking]
        let count = { (m: VoiceMode) in kinds.filter { m.allows($0) }.count }
        XCTAssertGreaterThan(count(.detailed), count(.standard))
        XCTAssertGreaterThan(count(.standard), count(.concise))
        XCTAssertGreaterThan(count(.concise), count(.alertsOnly))
        XCTAssertGreaterThan(count(.alertsOnly), count(.muted))
        XCTAssertTrue(VoiceMode.detailed.allows(.laneCue) && VoiceMode.detailed.allows(.straightReminder))
        XCTAssertFalse(VoiceMode.standard.allows(.laneCue))
        XCTAssertTrue(VoiceMode.standard.allows(.nowManeuver), "standard says the maneuver twice: heads-up and at the junction")
        XCTAssertFalse(VoiceMode.concise.allows(.nowManeuver))
        XCTAssertFalse(VoiceMode.alertsOnly.allows(.farManeuver))
    }

    func testTwoStageWording() {
        XCTAssertEqual(VoiceScript.far(distance: 120, instruction: "右轉進入中華路", withCue: false), "前方120公尺，右轉進入中華路")
        XCTAssertEqual(VoiceScript.now(instruction: "右轉進入中華路"), "此路口右轉進入中華路")
        XCTAssertEqual(VoiceScript.far(distance: 3, instruction: "左轉", withCue: false), "前方10公尺，左轉", "never announce under 10 m")
    }

    func testRampAndBridgeStepsGetALaneHintButNeverAClaimedSide() {
        let ramp = VoiceScript.far(distance: 300, instruction: "靠右進入國道一號匝道", withCue: true)
        XCTAssertTrue(ramp.contains("請提早切換到匝道的車道"))
        let bridge = VoiceScript.far(distance: 300, instruction: "上高架橋", withCue: true)
        XCTAssertTrue(bridge.contains("請提早靠近上橋的車道"))
        XCTAssertNil(VoiceScript.structureCue("右轉進入中華路"))
        XCTAssertEqual(VoiceScript.far(distance: 300, instruction: "上高架橋", withCue: false), "前方300公尺，上高架橋", "no hint when the mode does not ask for it")
        for text in [ramp, bridge] { XCTAssertFalse(text.contains("靠左車道") || text.contains("靠右車道")) }
    }

    func testLongStraightStretchIsAnnouncedOnlyWhenLong() {
        XCTAssertNil(VoiceScript.straight(meters: 900))
        XCTAssertEqual(VoiceScript.straight(meters: 2400), "接下來直行約2.4公里")
        XCTAssertEqual(VoiceScript.straight(meters: 23_000), "接下來直行約23公里")
    }

    func testChengGongJuniorHighPinIsMovedToTheRoadSideGate() throws {
        // what MapKit / OSM give for the pin, and a few metres either way
        let pin = CLLocationCoordinate2D(latitude: 24.8189739, longitude: 121.0172329)
        let a = try XCTUnwrap(RoadAnchors.anchor(for: pin))
        let toPin = CLLocation(latitude: a.anchor.latitude, longitude: a.anchor.longitude).distance(from: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
        XCTAssertGreaterThan(toPin, 60, "the anchor is on the road, not inside the campus")
        XCTAssertLessThan(toPin, 120)
        XCTAssertNotNil(RoadAnchors.anchor(for: CLLocationCoordinate2D(latitude: 24.81905, longitude: 121.01730)))
    }

    func testAPlaceElsewhereIsNotTouched() {
        XCTAssertNil(RoadAnchors.anchor(for: CLLocationCoordinate2D(latitude: 24.8393, longitude: 121.0093)))   // 竹北站
        XCTAssertNil(RoadAnchors.anchor(for: CLLocationCoordinate2D(latitude: 24.8189739, longitude: 121.0250)))   // 600+ m east of the school
    }
}
