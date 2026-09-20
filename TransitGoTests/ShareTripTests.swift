import XCTest
@testable import TransitGo

final class ShareTripTests: XCTestCase {

    func testTheRequestCarriesNoCoordinatesAndNoIdentity() throws {
        let route = try Nav.walkBusMrtWalk()
        let json = String(decoding: try ShareTripService.requestBody(route: route, title: "前往南京復興"), as: UTF8.self)
        for forbidden in ["fromLat", "fromLng", "toLat", "toLng", "latitude", "longitude", "deviceID", "deviceId", "location"] {
            XCTAssertFalse(json.contains(forbidden), "share request must not contain \(forbidden)")
        }
        XCTAssertTrue(json.contains("\"title\":\"前往南京復興\""))
        XCTAssertTrue(json.contains("\"ttlHours\":6"))
    }

    func testTheRequestKeepsWhatTheBackendNeedsToLookTheVehicleUp() throws {
        let route = try Nav.walkBusMrtWalk()
        let bodies = route.segments.map(ShareTripService.SegmentBody.init)
        XCTAssertEqual(bodies.map(\.mode), route.segments.map(\.mode))
        let ride = try XCTUnwrap(zip(route.segments, bodies).first { $0.0.mode != "WALK" })
        XCTAssertEqual(ride.1.from, ride.0.from)
        XCTAssertEqual(ride.1.to, ride.0.to)
        XCTAssertEqual(ride.1.tripId, ride.0.tripId)
        XCTAssertEqual(ride.1.departureTime, ride.0.departureTime)
    }

    func testAWalkOnlyTripIsNotShareableAndFailsBeforeAnyNetworkCall() async throws {
        let route = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.dest, fromName: "家", toName: "學校", dep: 0, arr: 600, distance: 700)])
        XCTAssertFalse(ShareTripService.isShareable(route))
        let result = await ShareTripService.create(route: route, title: "x")
        XCTAssertEqual(result.failure, .nothingToFollow)
    }

    func testATripWithAVehicleIsShareable() throws {
        XCTAssertTrue(ShareTripService.isShareable(try Nav.walkBusMrtWalk()))
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}
