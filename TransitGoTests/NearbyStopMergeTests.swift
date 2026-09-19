import XCTest
import CoreLocation
@testable import TransitGo

/// The nearby list must show highway coaches (InterCity) next to the city buses of the same pole.
final class NearbyStopMergeTests: XCTestCase {

    private func stop(_ uid: String, _ name: String, lat: Double = 24.8393, lon: Double = 121.0093) -> NearbyStop {
        let json: [String: Any] = [
            "StopUID": uid,
            "StopName": ["Zh_tw": name, "En": name],
            "StopPosition": ["PositionLat": lat, "PositionLon": lon],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(NearbyStop.self, from: data)
    }

    private func status(_ route: String) -> RealtimeStatus {
        let json: [String: Any] = ["mode": "BUS", "state": "normal", "source": "test", "routeName": route, "direction": 0, "etaSeconds": 300]
        return try! JSONDecoder().decode(RealtimeStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSameNamedCityAndInterCityStopsBecomeOneStopKeepingBothUIDLists() {
        let merged = MergedStop.group(
            city: [stop("HCC1", "竹北火車站")],
            interCity: [stop("IC9", "竹北火車站")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].stopUIDs, ["HCC1"])
        XCTAssertEqual(merged[0].interCityUIDs, ["IC9"])
    }

    func testInterCityOnlyStopIsKeptNotDropped() {
        let merged = MergedStop.group(city: [stop("HCC1", "竹北後火車站")], interCity: [stop("IC5", "飛利浦")])
        XCTAssertEqual(merged.count, 2)
        let philips = merged.first { $0.displayName == "飛利浦" }
        XCTAssertEqual(philips?.stopUIDs, [])
        XCTAssertEqual(philips?.interCityUIDs, ["IC5"])
    }

    func testTrailingZhanVariantAcrossFeedsIsTheSamePole() {
        let merged = MergedStop.group(city: [stop("HCC2", "天后宮站")], interCity: [stop("IC2", "天后宮")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].displayName, "天后宮")
    }

    func testTwoInterCityOnlyStopsAreNotEqual() {
        let a = MergedStop(stopUIDs: [], displayName: "甲", coordinate: nil, interCityUIDs: ["IC1"])
        let b = MergedStop(stopUIDs: [], displayName: "乙", coordinate: nil, interCityUIDs: ["IC2"])
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testInterCityAndCityRouteWithSameNumberDoNotCollapse() throws {
        var ic = try XCTUnwrap(StopArrival(realtime: status("5610")))
        ic.isInterCity = true
        let city = try XCTUnwrap(StopArrival(realtime: status("5610")))
        XCTAssertNotEqual(ic.id, city.id)
    }

    // MARK: backend response → stops

    private func backend(_ json: String) throws -> NearbyBusService.Response {
        try JSONDecoder().decode(NearbyBusService.Response.self, from: Data(json.utf8))
    }

    func testBackendStopsSplitIntoCityAndInterCityUIDs() throws {
        let r = try backend("""
        {"ok":true,"covered":true,"stops":[
          {"name":"竹北火車站","lat":24.84,"lon":121.0095,"distanceMeters":169,
           "stops":[{"scope":"City/HsinchuCounty","stopUID":"HSQ001"},{"scope":"InterCity","stopUID":"THB900"}]},
          {"name":"飛利浦","lat":24.841,"lon":121.005,"distanceMeters":400,
           "stops":[{"scope":"InterCity","stopUID":"THB902"}]}
        ]}
        """)
        let m = NearbyBusService.merged(r, city: .hsinchuCounty)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].stopUIDs, ["HSQ001"])
        XCTAssertEqual(m[0].interCityUIDs, ["THB900"])
        XCTAssertEqual(m[1].stopUIDs, [])
        XCTAssertEqual(m[1].interCityUIDs, ["THB902"])
    }

    func testStopOnlyKnownUnderAnotherCityIsDroppedNotShownEmpty() throws {
        let r = try backend("""
        {"ok":true,"covered":true,"stops":[
          {"name":"邊界站","lat":24.8,"lon":121.0,"distanceMeters":50,"stops":[{"scope":"City/Hsinchu","stopUID":"HSZ1"}]}
        ]}
        """)
        XCTAssertTrue(NearbyBusService.merged(r, city: .hsinchuCounty).isEmpty)
    }

    func testResponseDecodesTheNotCoveredSignal() throws {
        let r = try backend(#"{"ok":true,"radiusMeters":500,"covered":false,"stops":[]}"#)
        XCTAssertFalse(r.covered)
        XCTAssertTrue(r.stops.isEmpty)
    }
}
