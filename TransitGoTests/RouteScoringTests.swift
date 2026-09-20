import XCTest
@testable import TransitGo

final class RouteScoringTests: XCTestCase {
    private func opt(_ seconds: Double, _ steps: [String]) -> RouteOption {
        RouteOption(seconds: seconds, meters: seconds * 10, steps: steps.map { .init(instruction: $0, meters: 100) })
    }

    func testLaneStepsAreRecognisedByNumberedLaneNames() {
        XCTAssertTrue(RouteScoring.isLaneStep("左轉進入中華路1483巷"))
        XCTAssertTrue(RouteScoring.isLaneStep("右轉進入光明六路東二段57弄"))
        XCTAssertTrue(RouteScoring.isLaneStep("右轉進入三十六巷"))
        XCTAssertFalse(RouteScoring.isLaneStep("左轉進入中華路"))
        XCTAssertFalse(RouteScoring.isLaneStep("直行進入巷弄咖啡前的廣場"), "the character alone (no number) is not a lane step")
    }

    func testAMainRoadRouteBeatsAFasterLaneShortcutWhenTheDifferenceIsSmall() {
        let shortcut = opt(600, ["右轉進入中華路12巷", "左轉進入文興路3弄", "右轉進入自強南路87巷", "左轉進入中正東路"])   // 3 lane steps
        let main = opt(680, ["右轉進入中華路", "左轉進入中正東路"])
        // 600 + 3*75 = 825 vs 680
        XCTAssertEqual(RouteScoring.bestIndex([shortcut, main]), 1)
    }

    func testAFasterLaneRouteWinsWhenTheMainRoadIsMuchSlower() {
        let shortcut = opt(600, ["右轉進入中華路12巷"])
        let main = opt(1400, ["右轉進入中華路"])      // > 30 % and > 10 min slower: never chosen just for avoiding a lane
        XCTAssertEqual(RouteScoring.bestIndex([shortcut, main]), 0)
    }

    func testEqualScoresKeepTheFasterRouteAndSingleOrEmptyInputWork() {
        XCTAssertEqual(RouteScoring.bestIndex([opt(500, ["直行"]), opt(500, ["直行"])]), 0)
        XCTAssertEqual(RouteScoring.bestIndex([opt(500, ["直行"])]), 0)
        XCTAssertNil(RouteScoring.bestIndex([]))
    }

    func testTheSlowdownLimitAppliesToLongTripsAsSecondsToo() {
        let fast = opt(3600, ["右轉進入中華路12巷", "左轉進入文興路3弄", "右轉進入自強南路87巷", "左轉進入a路9巷"])   // 3600 + 300
        let slow = opt(4300, ["右轉進入中華路"])   // +700 s > 600 s cap even though < 30 %
        XCTAssertEqual(RouteScoring.bestIndex([fast, slow]), 0)
    }
}
