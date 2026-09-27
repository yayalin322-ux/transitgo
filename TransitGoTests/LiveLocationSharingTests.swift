import XCTest
@testable import TransitGo

/// "安全分享" (opt-in safety live-location): off by default on every share, and only ever turned
/// on for one specific link when the sharer explicitly says so — an inline toggle right on the
/// same share screen (TicketDetailView / TransferPlannerView / InAppNavigationView), never a
/// separate confirm page.
final class LiveLocationSharingTests: XCTestCase {
    func testATripShareDefaultsToLiveLocationOff() throws {
        let route = try Nav.walkBusMrtWalk()
        let json = String(decoding: try ShareTripService.requestBody(route: route, title: "x"), as: UTF8.self)
        XCTAssertTrue(json.contains("\"shareLiveLocation\":false"))
    }

    func testATripShareCanExplicitlyOptIn() throws {
        let route = try Nav.walkBusMrtWalk()
        let json = String(decoding: try ShareTripService.requestBody(route: route, title: "x", shareLiveLocation: true), as: UTF8.self)
        XCTAssertTrue(json.contains("\"shareLiveLocation\":true"))
    }

    func testPrepareCarriesTheFlagThroughToPrepared() throws {
        let route = try Nav.walkBusMrtWalk()
        let off = try XCTUnwrap(ShareTripService.prepare(route: route, title: "x").successValue)
        XCTAssertFalse(off.shareLiveLocation)
        let on = try XCTUnwrap(ShareTripService.prepare(route: route, title: "x", shareLiveLocation: true).successValue)
        XCTAssertTrue(on.shareLiveLocation)
    }

    func testANavShareDefaultsToLiveLocationOff() throws {
        let prepared = try XCTUnwrap(NavShareService.prepare(destinationName: "台北車站", mode: .walking).successValue)
        XCTAssertFalse(prepared.shareLiveLocation)
        let json = String(decoding: prepared.body, as: UTF8.self)
        XCTAssertTrue(json.contains("\"shareLiveLocation\":false"))
    }

    func testANavShareCanExplicitlyOptIn() throws {
        let prepared = try XCTUnwrap(NavShareService.prepare(destinationName: "台北車站", mode: .walking, shareLiveLocation: true).successValue)
        XCTAssertTrue(prepared.shareLiveLocation)
        let json = String(decoding: prepared.body, as: UTF8.self)
        XCTAssertTrue(json.contains("\"shareLiveLocation\":true"))
    }

    /// Even opted in, the CREATE request itself still never carries an actual coordinate — that
    /// only ever goes out later, per push, to /v1/shares/:token/location (see LiveLocationSharing).
    func testEvenAnOptedInShareRequestCarriesNoCoordinateYet() throws {
        let route = try Nav.walkBusMrtWalk()
        let json = String(decoding: try ShareTripService.requestBody(route: route, title: "x", shareLiveLocation: true), as: UTF8.self)
        for forbidden in ["lat", "lon", "latitude", "longitude"] {
            XCTAssertFalse(json.lowercased().contains(forbidden), "create request must not contain \(forbidden)")
        }
    }

    func testATicketShareDefaultsToLiveLocationOff() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        let ticket = RailTicket(system: .tra, serviceDate: day, trainNo: "152", trainType: "自強",
                                fromStationID: "1000", fromName: "臺北", toStationID: "1210", toName: "新竹",
                                depTime: "08:00", arrTime: "09:10", carNo: "5", seatNo: "23A", note: "")
        let json = String(decoding: try XCTUnwrap(try ShareTripService.requestBody(ticket: ticket)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"shareLiveLocation\":false"))
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { return v } else { return nil } }
}
