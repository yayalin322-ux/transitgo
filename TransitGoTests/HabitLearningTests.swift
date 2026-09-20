import XCTest
import CoreLocation
@testable import TransitGo

final class HabitLearningTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private let home = TripEndpoint(name: "家", kind: .address, latitude: 24.8393, longitude: 121.0093)
    private let work = TripEndpoint(name: "公司", kind: .address, latitude: 24.8130, longitude: 121.0245)
    private let gym = TripEndpoint(name: "健身房", kind: .address, latitude: 24.8300, longitude: 121.0200)
    private func spec(_ a: TripEndpoint, _ b: TripEndpoint) -> TripSpec { TripSpec(origin: a, destination: b) }

    // 2026-09-14 (Mon) … 09-18 (Fri) mornings home→work
    private func commuteEvents() -> [HabitEvent] {
        (14...18).map { HabitEvent(at: date(2026, 9, $0, 8, 10), spec: spec(home, work)) }
    }

    func testARepeatedWeekdayMorningTripIsSuggestedAtThatTime() {
        let s = HabitEngine.suggestions(from: commuteEvents(), now: date(2026, 9, 21, 8, 30), calendar: cal)   // Monday 08:30
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].spec.destination.name, "公司")
        XCTAssertEqual(s[0].matchingCount, 5)
        XCTAssertTrue(s[0].reason.contains("平日"))
    }

    func testNothingIsSuggestedAtAnUnrelatedTimeOrOnAWeekend() {
        let events = commuteEvents()
        XCTAssertTrue(HabitEngine.suggestions(from: events, now: date(2026, 9, 21, 15, 0), calendar: cal).isEmpty, "3 pm is not commute time")
        XCTAssertTrue(HabitEngine.suggestions(from: events, now: date(2026, 9, 20, 8, 30), calendar: cal).isEmpty, "Sunday is not a weekday")
    }

    func testTooFewOrSameDayEventsAreNotAHabit() {
        let two = Array(commuteEvents().prefix(2))
        XCTAssertTrue(HabitEngine.suggestions(from: two, now: date(2026, 9, 21, 8, 30), calendar: cal).isEmpty)
        let oneDayThrice = [date(2026, 9, 14, 8, 0), date(2026, 9, 14, 8, 40), date(2026, 9, 14, 9, 10)].map { HabitEvent(at: $0, spec: spec(home, work)) }
        XCTAssertTrue(HabitEngine.suggestions(from: oneDayThrice, now: date(2026, 9, 21, 8, 30), calendar: cal).isEmpty, "one busy morning is not a routine")
    }

    func testRecentPatternOutranksAnOldOneAndExcludedTripsAreSkipped() {
        var events = commuteEvents()   // home→work, last week
        // gym: also 3 matching mornings but 60–70 days ago
        events += [date(2026, 7, 13, 8, 0), date(2026, 7, 20, 8, 0), date(2026, 7, 27, 8, 0)].map { HabitEvent(at: $0, spec: spec(home, gym)) }
        let now = date(2026, 9, 21, 8, 30)
        let s = HabitEngine.suggestions(from: events, now: now, calendar: cal, limit: 2)
        XCTAssertEqual(s.map { $0.spec.destination.name }, ["公司", "健身房"])
        let skipped = HabitEngine.suggestions(from: events, now: now, calendar: cal, excluding: [spec(home, work).identity])
        XCTAssertEqual(skipped.map { $0.spec.destination.name }, ["健身房"])
    }

    func testRecordingDedupesQuickRepeatsTrimsOldEventsAndRejectsInvalidTrips() {
        let t = date(2026, 9, 21, 8, 0)
        var e = HabitEngine.recording(spec(home, work), at: t, into: [])
        e = HabitEngine.recording(spec(home, work), at: t.addingTimeInterval(5 * 60), into: e)
        XCTAssertEqual(e.count, 1, "planning the same trip twice in 5 minutes is one intention")
        e = HabitEngine.recording(spec(home, work), at: t.addingTimeInterval(3 * 3600), into: e)
        XCTAssertEqual(e.count, 2)
        e = HabitEngine.recording(spec(home, home), at: t, into: e)
        XCTAssertEqual(e.count, 2, "origin == destination is not a trip")
        let old = [HabitEvent(at: t.addingTimeInterval(-200 * 86_400), spec: spec(home, gym))]
        XCTAssertTrue(HabitEngine.recording(spec(home, work), at: t, into: old).allSatisfy { $0.spec.destination.name != "健身房" }, "events over 120 days old are dropped")
    }

    func testTimeMatchingWrapsAroundMidnight() {
        XCTAssertTrue(HabitEngine.matches(date(2026, 9, 15, 23, 40), now: date(2026, 9, 16, 0, 20), calendar: cal))
        XCTAssertFalse(HabitEngine.matches(date(2026, 9, 15, 20, 0), now: date(2026, 9, 16, 8, 0), calendar: cal))
    }

    @MainActor func testLogPersistsToDiskAndClearRemovesEverything() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("habits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: HabitLog.enabledKey)
        let log = HabitLog(url: url)
        log.record(spec(home, work), at: date(2026, 9, 14, 8, 0))
        log.record(spec(home, work), at: date(2026, 9, 15, 8, 0))
        XCTAssertEqual(HabitLog(url: url).events.count, 2, "a new instance (app restart) reads the same events")
        log.clear()
        XCTAssertTrue(HabitLog(url: url).events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testSwitchingItOffStopsRecordingAndSuggesting() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("habits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: HabitLog.enabledKey) }
        UserDefaults.standard.set(false, forKey: HabitLog.enabledKey)
        let log = HabitLog(url: url)
        log.record(spec(home, work), at: date(2026, 9, 14, 8, 0))
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(log.suggestions(now: date(2026, 9, 21, 8, 30)).isEmpty)
    }
}
