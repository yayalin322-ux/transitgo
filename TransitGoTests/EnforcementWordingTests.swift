import XCTest
@testable import TransitGo

final class EnforcementWordingTests: XCTestCase {
    private func cam(kind: String, note: String?, limit: Int? = nil) throws -> SpeedCam {
        var d: [String: Any] = ["lat": 24.83, "lon": 121.0, "kind": kind, "source": "test"]
        if let note { d["note"] = note }
        if let limit { d["speedLimit"] = limit }
        return try JSONDecoder().decode(SpeedCam.self, from: JSONSerialization.data(withJSONObject: d))
    }

    func testJunctionCameraSaysWhatItActuallyEnforces() throws {
        let c = try cam(kind: "intersection", note: "闖紅燈、車輛不禮讓行人")
        XCTAssertEqual(c.announcement, "前方路口科技執法，取締闖紅燈、不停讓行人")
    }

    func testLongListIsCappedAtThreeAndSpeedItemsAreDropped() {
        let spoken = EnforcementWording.spoken("闖紅燈、測速、未依標誌標線號誌行駛、機車未依規定兩段式左轉、違規停車")
        XCTAssertEqual(spoken, "闖紅燈、不依號誌標線行駛、機車兩段式左轉")
    }

    func testEveryCategoryInTheCountyPDFHasWording() {
        for item in ["闖紅燈", "車輛不禮讓行人", "違規迴轉", "機車未依規定兩段式左轉", "跨越雙白線", "未保持路口淨空",
                     "未依標誌標線號誌行駛", "不遵守道路交通標誌、標線、號誌之指示", "機車不在規定車道行駛", "違規（臨時）停車", "違規上客", "違規攬客"] {
            XCTAssertNotNil(EnforcementWording.spoken(item), "no wording for 取締項目 \(item)")
        }
    }

    func testMissingOrUnrecognisedNoteKeepsTheGenericLine() throws {
        XCTAssertEqual(try cam(kind: "intersection", note: nil).announcement, "前方有路口違規照相")
        XCTAssertEqual(try cam(kind: "intersection", note: "其他").announcement, "前方有路口違規照相")
        XCTAssertEqual(try cam(kind: "speed", note: "闖紅燈", limit: 50).announcement, "前方有測速照相，速限50公里")
    }

    func testParkingCameraAnnouncement() throws {
        XCTAssertEqual(try cam(kind: "violation", note: "違規（臨時）停車、違規上客、違規攬客").announcement, "前方有違規照相，取締違規停車、違規上客、違規攬客")
    }
}
