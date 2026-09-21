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

    func testAWalkOnlyTripIsNotShareableAndNothingIsPrepared() throws {
        let route = try Nav.route([Nav.Seg(mode: "WALK", from: Nav.home, to: Nav.dest, fromName: "家", toName: "學校", dep: 0, arr: 600, distance: 700)])
        XCTAssertFalse(ShareTripService.isShareable(route))
        XCTAssertEqual(ShareTripService.prepare(route: route, title: "x").failureValue, .nothingToFollow)
    }

    func testATripWithAVehicleIsShareable() throws {
        XCTAssertTrue(ShareTripService.isShareable(try Nav.walkBusMrtWalk()))
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}

// MARK: - Sharing a ticket from the 車票 page

final class ShareTicketTests: XCTestCase {
    private func ticket(system: RailSystem = .tra, date: Date? = nil) -> RailTicket {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let day = date ?? cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        return RailTicket(system: system, serviceDate: day, trainNo: "152", trainType: "自強",
                          fromStationID: "1000", fromName: "臺北", toStationID: "1210", toName: "新竹",
                          depTime: "08:00", arrTime: "09:10", carNo: "5", seatNo: "23A", note: "靠窗，王小明")
    }

    func testATrainTicketBecomesOneTrainLegTheBackendCanLookUp() throws {
        let seg = try XCTUnwrap(ShareTripService.segment(for: ticket()))
        XCTAssertEqual(seg.mode, "TRA")
        XCTAssertEqual(seg.tripId, "TRA_152_2026-09-21")
        XCTAssertEqual(seg.from, "TRA:1000")
        XCTAssertEqual(seg.to, "TRA:1210")
        XCTAssertEqual(seg.fromName, "臺北")
        XCTAssertEqual(seg.toName, "新竹")
        XCTAssertEqual(seg.line, "自強 152", "recipients see the train type and number")
        XCTAssertEqual(seg.departureTime, "2026-09-21T00:00:00Z", "08:00 Taipei")
        XCTAssertEqual(seg.arrivalTime, "2026-09-21T01:10:00Z")
    }

    func testTheRequestNeverContainsSeatCarNoteOrAnyLocation() throws {
        let json = String(decoding: try XCTUnwrap(try ShareTripService.requestBody(ticket: ticket())), as: UTF8.self)
        for secret in ["23A", "王小明", "靠窗", "carNo", "seatNo", "note", "5 車", "latitude", "longitude", "Lat", "Lng"] {
            XCTAssertFalse(json.contains(secret), "share request must not contain \(secret)")
        }
        XCTAssertTrue(json.contains("\"ttlHours\":12"))
        XCTAssertTrue(json.contains("臺北 → 新竹・自強 152"))
    }

    func testAHighSpeedRailTicketIsSharedAsScheduleOnly() throws {
        let seg = try XCTUnwrap(ShareTripService.segment(for: ticket(system: .thsr)))
        XCTAssertEqual(seg.mode, "HSR")
        XCTAssertNil(seg.tripId, "there is no per-train live feed for 高鐵, so nothing to look up")
    }

    func testATicketWithAnUnreadableTimeCannotBeShared() {
        let bad = ticket()
        bad.depTime = "??"
        XCTAssertNil(ShareTripService.segment(for: bad))
        XCTAssertEqual(ShareTripService.prepare(ticket: bad).failureValue, .nothingToFollow)
    }

    func testTheTripDateIsTheTaipeiCalendarDayEvenNearMidnight() throws {
        // 2026-09-21 00:30 Taipei is still 09-20 in UTC — the train id must use the Taipei day.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let t = ticket(date: cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 0, minute: 30))!)
        XCTAssertEqual(try XCTUnwrap(ShareTripService.segment(for: t)).tripId, "TRA_152_2026-09-21")
    }
}
