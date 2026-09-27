import XCTest
import CoreLocation
@testable import TransitGo

final class NavShareTests: XCTestCase {
    func testTheRequestCarriesNoCoordinatesAndNoIdentity() throws {
        let prepared = try XCTUnwrap(NavShareService.prepare(destinationName: "台北車站", mode: .automobile).successValue)
        let json = String(decoding: prepared.body, as: UTF8.self)
        // "shareLiveLocation" (the 安全分享 opt-in flag, off here) legitimately contains the
        // substring "location" — check for that field's exact off-value instead of banning the
        // word outright, and keep the ban for every field name that would actually carry a value.
        XCTAssertTrue(json.contains("\"shareLiveLocation\":false"))
        for forbidden in ["lat", "lon", "latitude", "longitude", "deviceID", "deviceId", "coordinate"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()), "nav share request must not contain \(forbidden)")
        }
        XCTAssertTrue(json.contains("\"kind\":\"nav\""))
        XCTAssertTrue(json.contains("\"title\":\"前往台北車站\""))
        XCTAssertTrue(json.contains("\"mode\":\"automobile\""))
        XCTAssertTrue(json.contains("\"destinationName\":\"台北車站\""))
    }

    func testEachModeEncodesItsOwnRawValueTheServerExpects() throws {
        for (mode, raw) in [(NavShareService.Mode.automobile, "automobile"), (.scooter, "scooter"), (.walking, "walking")] {
            let prepared = try XCTUnwrap(NavShareService.prepare(destinationName: "x", mode: mode).successValue)
            let json = String(decoding: prepared.body, as: UTF8.self)
            XCTAssertTrue(json.contains("\"mode\":\"\(raw)\""), "mode \(mode) should encode as \(raw)")
        }
    }

    func testTheTokenIsAValidShareToken() throws {
        let prepared = try XCTUnwrap(NavShareService.prepare(destinationName: "x", mode: .walking).successValue)
        XCTAssertTrue(ShareLink.isValid(prepared.token))
        XCTAssertEqual(prepared.url.lastPathComponent, prepared.token)
    }

    func testEveryPrepareCallMakesAFreshUnguessableToken() throws {
        let a = try XCTUnwrap(NavShareService.prepare(destinationName: "x", mode: .automobile).successValue)
        let b = try XCTUnwrap(NavShareService.prepare(destinationName: "x", mode: .automobile).successValue)
        XCTAssertNotEqual(a.token, b.token)
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { return v } else { return nil } }
}
