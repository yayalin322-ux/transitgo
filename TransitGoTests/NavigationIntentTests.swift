import XCTest
import MapKit
@testable import TransitGo

@MainActor
final class NavigationIntentTests: XCTestCase {

    func testSpokenDestinationIsRecordedForTheUI() async throws {
        PendingNavigation.shared.clear()
        var intent = StartNavigationIntent()
        intent.destination = "  竹北車站 "
        intent.mode = .scooter
        _ = try await intent.perform()
        let r = try XCTUnwrap(PendingNavigation.shared.request)
        XCTAssertEqual(r.query, "竹北車站")           // trimmed
        XCTAssertEqual(r.mode, .scooter)
        PendingNavigation.shared.clear()
        XCTAssertNil(PendingNavigation.shared.request)
    }

    func testBlankDestinationIsRefusedSoSiriAsksAgain() async {
        PendingNavigation.shared.clear()
        var intent = StartNavigationIntent()
        intent.destination = "   "
        intent.mode = .drive
        do { _ = try await intent.perform(); XCTFail("a blank destination must not start navigation") } catch {}
        XCTAssertNil(PendingNavigation.shared.request)
    }

    func testModesMapToTheRightRoutingAndFreewayRule() {
        XCTAssertEqual(SiriTravelMode.drive.transportType, .automobile)
        XCTAssertNil(SiriTravelMode.drive.avoidsHighways)              // a car may use 國道
        XCTAssertEqual(SiriTravelMode.scooter.transportType, .automobile)
        XCTAssertEqual(SiriTravelMode.scooter.avoidsHighways, true)    // a scooter may not
        XCTAssertEqual(SiriTravelMode.walk.transportType, .walking)
    }

    func testEveryDrivingModeIsOfferedToSiri() {
        XCTAssertEqual(Set(SiriTravelMode.allCases), [.drive, .scooter, .walk])
        XCTAssertEqual(SiriTravelMode.caseDisplayRepresentations.count, 3)
    }
}
