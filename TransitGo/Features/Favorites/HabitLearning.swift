import Foundation

/// What the app learns about your routine — entirely on this phone. Every planned journey is logged
/// (which trip, when); at a given day-type and hour the trips you repeatedly make around then are offered
/// on the home page ("現在常去"). Nothing is uploaded, and it can be switched off and wiped in Settings.
struct HabitEvent: Codable, Equatable {
    var at: Date
    var origin: TripEndpoint
    var destination: TripEndpoint
    var profile: TripProfile

    init(at: Date, spec: TripSpec) { self.at = at; origin = spec.origin; destination = spec.destination; profile = spec.profile }
    var spec: TripSpec { TripSpec(origin: origin, destination: destination, profile: profile) }
}

struct HabitSuggestion: Equatable {
    let spec: TripSpec
    /// Journeys that fell at about this time of day on this kind of day.
    let matchingCount: Int
    let reason: String
}

enum HabitEngine {
    /// Same trip planned again within this window is one intention, not several.
    static let dedupeWindow: TimeInterval = 20 * 60
    static let maxEvents = 600
    static let maxAgeDays = 120.0
    /// An event this many days old counts half as much as one from today.
    static let halfLifeDays = 21.0
    /// Hours either side of now that count as "about this time".
    static let hourWindow = 1.5
    /// A pattern needs at least this many matching journeys, on at least this many different days.
    static let minMatches = 3
    static let minDistinctDays = 2

    /// Adds an event unless the same trip was logged moments ago; trims old and excess events.
    static func recording(_ spec: TripSpec, at date: Date, into events: [HabitEvent]) -> [HabitEvent] {
        guard spec.isValid else { return events }
        var out = events
        if let last = out.last(where: { $0.spec.identity == spec.identity }), abs(date.timeIntervalSince(last.at)) < dedupeWindow {
            return out
        }
        out.append(HabitEvent(at: date, spec: spec))
        let cutoff = date.addingTimeInterval(-maxAgeDays * 86_400)
        out = out.filter { $0.at >= cutoff }
        if out.count > maxEvents { out = Array(out.suffix(maxEvents)) }
        return out
    }

    /// Weekday vs weekend, and the time of day, decide whether an old journey matches "now".
    static func matches(_ event: Date, now: Date, calendar: Calendar) -> Bool {
        let isWeekend = { (d: Date) in calendar.isDateInWeekend(d) }
        guard isWeekend(event) == isWeekend(now) else { return false }
        return circularHourDistance(hourOfDay(event, calendar), hourOfDay(now, calendar)) <= hourWindow
    }

    static func suggestions(from events: [HabitEvent], now: Date, calendar: Calendar = .current,
                            excluding excluded: Set<String> = [], limit: Int = 2) -> [HabitSuggestion] {
        var byTrip: [String: [HabitEvent]] = [:]
        for e in events where !excluded.contains(e.spec.identity) && e.at <= now { byTrip[e.spec.identity, default: []].append(e) }

        var scored: [(HabitSuggestion, Double)] = []
        for (_, group) in byTrip {
            let hits = group.filter { matches($0.at, now: now, calendar: calendar) }
            let days = Set(hits.map { calendar.startOfDay(for: $0.at) })
            guard hits.count >= minMatches, days.count >= minDistinctDays, let latest = group.max(by: { $0.at < $1.at }) else { continue }
            let score = hits.reduce(0.0) { acc, e in
                let ageDays = now.timeIntervalSince(e.at) / 86_400
                return acc + pow(0.5, ageDays / halfLifeDays)
            }
            let dayType = calendar.isDateInWeekend(now) ? "假日" : "平日"
            let hour = calendar.component(.hour, from: now)
            scored.append((HabitSuggestion(spec: latest.spec, matchingCount: hits.count,
                                           reason: "\(dayType)\(String(format: "%02d", hour)):00 前後你常這樣走（\(hits.count) 次）"), score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func hourOfDay(_ d: Date, _ c: Calendar) -> Double {
        Double(c.component(.hour, from: d)) + Double(c.component(.minute, from: d)) / 60
    }
    private static func circularHourDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 24 - d)
    }
}

/// The on-device log. A plain JSON file in Application Support — not iCloud, not the network.
@MainActor
final class HabitLog {
    static let shared = HabitLog()
    static let enabledKey = "habits.enabled"

    private let url: URL
    private(set) var events: [HabitEvent]

    init(url: URL? = nil) {
        let base = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("habits.json")
        self.url = base
        events = (try? JSONDecoder.iso.decode([HabitEvent].self, from: Data(contentsOf: base))) ?? []
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func record(_ spec: TripSpec, at date: Date = Date()) {
        guard isEnabled else { return }
        events = HabitEngine.recording(spec, at: date, into: events)
        save()
    }

    func suggestions(now: Date = Date(), excluding: Set<String> = []) -> [HabitSuggestion] {
        guard isEnabled else { return [] }
        return HabitEngine.suggestions(from: events, now: now, excluding: excluding)
    }

    /// Settings → 清除學習資料.
    func clear() { events = []; try? FileManager.default.removeItem(at: url) }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(events) { try? data.write(to: url, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
