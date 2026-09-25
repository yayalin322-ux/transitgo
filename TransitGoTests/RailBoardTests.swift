import XCTest
@testable import TransitGo

final class RailBoardTests: XCTestCase {

    // Shape of the backend's answer (transitgo-server/src/realtime/railBoard.mjs), values from real 2026-09-19 rows.
    private let json = """
    {"ok":true,"available":true,"stale":false,"fetchedAt":1789000000000,
     "station":{"id":"1000","name":"臺北"},
     "northbound":[{"trainNo":"1281","type":"區間","dest":"基隆","depart":"13:58","delayMinutes":0,"platform":null,"heading":"north"}],
     "southbound":[{"trainNo":"428","type":"自強(3000)","dest":"新左營","depart":"13:52","delayMinutes":1,"platform":"2","heading":"south"},
                   {"trainNo":"3187","type":"區間","dest":"潮州","depart":"14:05","delayMinutes":9,"platform":null,"heading":"south"}],
     "other":[],"headingsKnown":true}
    """

    private func taipei(_ hm: String, day: Int = 19) -> Date {
        let p = hm.split(separator: ":").map { Int($0)! }
        return RailBoard.taipei.date(from: DateComponents(year: 2026, month: 9, day: day, hour: p[0], minute: p[1]))!
    }
    private func train(_ depart: String, delay: Int? = 0, heading: String = "south") -> RailBoardTrain {
        try! JSONDecoder().decode(RailBoardTrain.self, from: Data("""
        {"trainNo":"1","type":"區間","dest":"X","depart":"\(depart)","delayMinutes":\(delay.map(String.init) ?? "null"),"platform":null,"heading":"\(heading)"}
        """.utf8))
    }

    func testDecodesTheBackendAnswer() throws {
        let b = try JSONDecoder().decode(RailBoard.self, from: Data(json.utf8))
        XCTAssertEqual(b.stationName, "臺北")
        XCTAssertEqual(b.northbound.count, 1)
        XCTAssertEqual(b.southbound.map(\.dest), ["新左營", "潮州"])
        XCTAssertEqual(b.southbound[0].platform, "2")
        XCTAssertTrue(b.headingsKnown)
    }

    func testAnUnavailableAnswerDecodesToEmptyListsNotInventedTrains() throws {
        let b = try JSONDecoder().decode(RailBoard.self, from: Data(#"{"ok":true,"available":false,"reason":"rate_limited","station":{"id":"1000"}}"#.utf8))
        XCTAssertFalse(b.available)
        XCTAssertTrue(b.northbound.isEmpty && b.southbound.isEmpty && b.other.isEmpty)
        XCTAssertEqual(b.stationName, "1000")
        XCTAssertTrue(b.spoken(heading: .north, at: taipei("13:00")).contains("查不到"))
    }

    func testMinutesUntilCountsDelayAndWrapsAtMidnight() {
        XCTAssertEqual(train("13:20", delay: 0).minutesUntil(taipei("13:10")), 10)
        XCTAssertEqual(train("13:05", delay: 20).minutesUntil(taipei("13:10")), 15)     // late trains are still coming
        XCTAssertEqual(train("13:00", delay: nil).minutesUntil(taipei("13:10")), -10)
        XCTAssertEqual(train("00:10", delay: 0).minutesUntil(taipei("23:55")), 15)       // next day, not 23 h ago
        XCTAssertEqual(train("23:50", delay: 0).minutesUntil(taipei("00:05", day: 20)), -15)
    }

    func testUpcomingDropsDepartedTrainsAndSortsSoonestFirst() {
        let list = [train("13:40"), train("13:12"), train("13:00"), train("13:09")]
        let up = RailBoard.upcoming(list, at: taipei("13:10"))
        XCTAssertEqual(up.map(\.depart), ["13:09", "13:12", "13:40"])   // 13:09 is inside the 1-minute grace, 13:00 is gone
    }

    func testSpokenAnswerForNextTrain() throws {
        let b = try JSONDecoder().decode(RailBoard.self, from: Data(json.utf8))
        let s = b.spoken(heading: .south, at: taipei("13:45"))
        XCTAssertTrue(s.contains("臺北站下一班南下"), s)
        XCTAssertTrue(s.contains("13:52開往新左營"), s)
        XCTAssertTrue(s.contains("8 分鐘後"), s)              // 13:52 + 1 min late = 13:53, from 13:45
        XCTAssertTrue(s.contains("誤點1分鐘"), s)
        XCTAssertTrue(b.spoken(heading: .north, at: taipei("13:45")).contains("開往基隆"))
    }

    func testSpokenWhenNothingIsComing() throws {
        let b = try JSONDecoder().decode(RailBoard.self, from: Data(json.utf8))
        XCTAssertTrue(b.spoken(heading: .south, at: taipei("15:00")).contains("目前沒有南下的班次"))
    }

    func testDelayText() {
        XCTAssertEqual(train("13:00", delay: 5).delayText, "誤點 5 分")
        XCTAssertEqual(train("13:00", delay: 0).delayText, "準點")
        XCTAssertNil(train("13:00", delay: nil).delayText)
    }
}
