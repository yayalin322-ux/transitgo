import XCTest
@testable import TransitGo

/// Google-Maps-style business info: the photo gallery/legacy-photo fallback, structured hours'
/// encode behaviour (the server rejects anything but exactly 7 keys), and feature tags never
/// failing a whole landmark's decode over one tag this build doesn't recognize yet.
final class LandmarkBusinessInfoTests: XCTestCase {
    private func decode(_ json: String) throws -> UserLandmark {
        try JSONDecoder().decode(UserLandmark.self, from: Data(json.utf8))
    }

    private let base = """
    {"id":1,"name":"測試店","description":"","category":"restaurant","lat":24.8,"lon":121.0,
     "photo":null,"businessHours":null,"phone":null,"businessVerified":true,"businessStatus":"open",
     "approved":true,"isBusinessClaim":true
    """

    // ---- photos: legacy fallback ----
    func testNoPhotosFieldAtAllFallsBackToTheLegacySinglePhoto() throws {
        let l = try decode(base.replacingOccurrences(of: "\"photo\":null", with: "\"photo\":\"https://x/a.jpg\"") + "}")
        XCTAssertEqual(l.effectivePhotos, ["https://x/a.jpg"])
    }

    func testNoPhotoAtAllMeansAnEmptyGallery() throws {
        let l = try decode(base + "}")
        XCTAssertEqual(l.effectivePhotos, [])
    }

    func testARealGalleryIsUsedAsIs() throws {
        let l = try decode(base + ",\"photos\":[\"https://x/a.jpg\",\"https://x/b.jpg\"]}")
        XCTAssertEqual(l.effectivePhotos, ["https://x/a.jpg", "https://x/b.jpg"])
    }

    // ---- features: one unrecognized tag never fails the whole decode ----
    func testKnownFeaturesDecodeToRealTags() throws {
        let l = try decode(base + ",\"features\":[\"parking\",\"wifi\"]}")
        XCTAssertEqual(l.featureTags, [.parking, .wifi])
    }

    func testAnUnrecognizedFeatureIsSkippedNotAFailure() throws {
        let l = try decode(base + ",\"features\":[\"parking\",\"some-future-tag-this-build-does-not-know\",\"wifi\"]}")
        XCTAssertEqual(l.featureTags, [.parking, .wifi], "the whole landmark must still decode, with the unknown tag just dropped")
    }

    // ---- hours: decode + the encode-side "always 7 keys" requirement ----
    func testStructuredHoursDecode() throws {
        let l = try decode(base + ",\"hours\":{\"mon\":{\"open\":\"09:00\",\"close\":\"18:00\"},\"tue\":null,\"wed\":null,\"thu\":null,\"fri\":null,\"sat\":null,\"sun\":null}}")
        XCTAssertEqual(l.hours?.mon, DayHours(open: "09:00", close: "18:00"))
        XCTAssertNil(l.hours?.tue)
    }

    func testEncodingHoursAlwaysEmitsAllSevenKeysEvenForClosedDays() throws {
        // The server's sanitizeHours rejects anything but exactly the 7 named keys — a naive
        // synthesized encoder would OMIT a nil (closed) day's key entirely instead of writing
        // `null`, which would make every edit that closes a day get rejected outright.
        var hours = LandmarkHours()
        hours.mon = DayHours(open: "09:00", close: "18:00")
        // tue...sun left nil (closed)
        let data = try JSONEncoder().encode(hours)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] {
            XCTAssertTrue(obj.keys.contains(key), "missing key \(key) — the server would reject this as an incomplete week")
        }
        XCTAssertTrue(obj["tue"] is NSNull, "a closed day must encode as a real JSON null, not be omitted")
    }

    func testDaysListsInMondayFirstOrder() {
        var hours = LandmarkHours()
        hours.setHours(DayHours(open: "10:00", close: "20:00"), forKey: "sat")
        XCTAssertEqual(hours.days.map(\.key), ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        XCTAssertEqual(hours.days.first { $0.key == "sat" }?.hours, DayHours(open: "10:00", close: "20:00"))
    }

    // ---- openNow ----
    func testOpenNowDecodesWhenPresent() throws {
        let l = try decode(base + ",\"openNow\":{\"open\":true,\"changesAt\":\"18:00\",\"changesLabel\":\"今天 18:00 打烊\"}}")
        XCTAssertEqual(l.openNow?.open, true)
        XCTAssertEqual(l.openNow?.changesLabel, "今天 18:00 打烊")
    }

    func testOpenNowIsNilWithoutStructuredHours() throws {
        let l = try decode(base + "}")
        XCTAssertNil(l.openNow)
    }
}
