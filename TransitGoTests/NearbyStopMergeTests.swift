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
}
