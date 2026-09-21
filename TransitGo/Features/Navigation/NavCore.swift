import Foundation
import CoreLocation

// Pure navigation building blocks for the in-app turn-by-turn screen. No UIKit, no MapKit route
// objects — only coordinates and numbers — so every rule below is unit-tested with synthetic traces.

// MARK: - Local metric geometry

/// Equirectangular projection around one origin: metres east/north. Plenty accurate for a route
/// (error well under 0.5 % over tens of km at Taiwan's latitude) and far cheaper than haversine
/// per segment.
struct LocalFrame {
    let lat0: Double, lon0: Double
    private let cosLat: Double
    init(origin: CLLocationCoordinate2D) {
        lat0 = origin.latitude; lon0 = origin.longitude
        cosLat = cos(origin.latitude * .pi / 180)
    }
    func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - lon0) * cosLat * 111_320, (c.latitude - lat0) * 110_540)
    }
    func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat0 + y / 110_540, longitude: lon0 + x / (cosLat * 111_320))
    }
}

// MARK: - Route track (projection of a fix onto the planned polyline)

/// The planned route as a polyline with cumulative length, so a GPS fix can be turned into
/// "how far from the route" and "how far along it" — distances measured along the road, not as the
/// crow flies. Straight-line distance to the destination (what the screen used before) is wrong
/// on any route that bends, and projecting onto *segments* (not just vertices) avoids false
/// "off route" readings on long straight stretches where MapKit stores few points.
struct RouteTrack {
    struct Projection {
        let distanceFromRoute: Double
        let alongMeters: Double
        let snapped: CLLocationCoordinate2D
        /// Direction of the route segment the fix projects onto, degrees clockwise from north.
        let bearingDegrees: Double
    }

    let coordinates: [CLLocationCoordinate2D]
    let totalMeters: Double
    private let frame: LocalFrame
    private let pts: [(x: Double, y: Double)]
    private let cumulative: [Double]

    init?(coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count >= 2 else { return nil }
        let frame = LocalFrame(origin: coordinates[0])
        let pts = coordinates.map { frame.xy($0) }
        var cum = [0.0]
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        guard cum[cum.count - 1] > 0 else { return nil }
        self.coordinates = coordinates
        self.frame = frame
        self.pts = pts
        self.cumulative = cum
        self.totalMeters = cum[cum.count - 1]
    }

    var end: CLLocationCoordinate2D { coordinates[coordinates.count - 1] }

    /// Nearest point on the route. `after` (an along-distance already reached) keeps the search from
    /// snapping backwards onto an earlier part of a route that doubles back on itself; if nothing
    /// ahead is found the whole route is searched.
    func project(_ c: CLLocationCoordinate2D, after: Double? = nil) -> Projection {
        let p = frame.xy(c)
        func search(minAlong: Double) -> Projection? {
            var best: Projection?
            for i in 0..<(pts.count - 1) {
                if cumulative[i + 1] < minAlong { continue }
                let a = pts[i], b = pts[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let sx = a.x + t * dx, sy = a.y + t * dy
                let d = hypot(p.x - sx, p.y - sy)
                if best == nil || d < best!.distanceFromRoute {
                    var bearing = atan2(dx, dy) * 180 / .pi
                    if bearing < 0 { bearing += 360 }
                    best = Projection(
                        distanceFromRoute: d,
                        alongMeters: cumulative[i] + t * sqrt(len2),
                        snapped: frame.coordinate(x: sx, y: sy),
                        bearingDegrees: bearing
                    )
                }
            }
            return best
        }
        if let after, let hit = search(minAlong: max(0, after - 30)) { return hit }
        return search(minAlong: 0)!
    }

    func remainingMeters(fromAlong along: Double) -> Double { max(0, totalMeters - along) }
}

// MARK: - GPS fix filter

/// Rejects fixes that would mislead navigation and smooths the rest with a small Kalman filter
/// (per axis, process noise from the current speed). A raw fix between tall buildings can be tens
/// of metres off and jump back a second later — that is what made the blue dot leap, "arrived"
/// fire early and reroutes trigger on a good road.
struct NavLocationFilter {
    private(set) var last: CLLocation?
    private var variance = 0.0
    private var frame: LocalFrame?
    private var consecutiveRejects = 0

    static let maxAge: TimeInterval = 8
    static let maxAccuracy: Double = 65
    static let maxPlausibleSpeed: Double = 60   // m/s ≈ 216 km/h

    /// Returns the fix to use, or nil when it should be ignored.
    mutating func process(_ raw: CLLocation, now: Date = Date()) -> CLLocation? {
        guard raw.horizontalAccuracy >= 0, raw.horizontalAccuracy <= Self.maxAccuracy else { return reject() }
        guard now.timeIntervalSince(raw.timestamp) <= Self.maxAge else { return reject() }

        guard let last, let frame else {
            self.frame = LocalFrame(origin: raw.coordinate)
            variance = raw.horizontalAccuracy * raw.horizontalAccuracy
            consecutiveRejects = 0
            self.last = raw
            return raw
        }
        let dt = raw.timestamp.timeIntervalSince(last.timestamp)
        guard dt > 0 else { return reject() }            // out of order / duplicate

        let a = frame.xy(last.coordinate), m = frame.xy(raw.coordinate)
        let jump = hypot(m.x - a.x, m.y - a.y)
        // A physically impossible leap from a mediocre fix is noise. Several in a row mean we really
        // moved (tunnel exit, long GPS gap) — then trust it and restart the filter there.
        if jump / dt > Self.maxPlausibleSpeed, raw.horizontalAccuracy > 20, consecutiveRejects < 3 { return reject() }
        if jump / dt > Self.maxPlausibleSpeed {
            self.frame = LocalFrame(origin: raw.coordinate)
            variance = raw.horizontalAccuracy * raw.horizontalAccuracy
            consecutiveRejects = 0
            self.last = raw
            return raw
        }

        // Predict: the position could have moved about `speed` metres per second since the last fix.
        let q = max(last.speed >= 0 ? last.speed : 3, 1.5)
        variance += dt * q * q
        // Update: weight the new fix by how much better it is than the prediction.
        let acc2 = raw.horizontalAccuracy * raw.horizontalAccuracy
        let k = variance / (variance + acc2)
        let nx = a.x + k * (m.x - a.x), ny = a.y + k * (m.y - a.y)
        variance = (1 - k) * variance
        consecutiveRejects = 0

        let smoothed = CLLocation(
            coordinate: frame.coordinate(x: nx, y: ny),
            altitude: raw.altitude,
            horizontalAccuracy: max(3, sqrt(variance)),
            verticalAccuracy: raw.verticalAccuracy,
            course: raw.course,
            speed: raw.speed,
            timestamp: raw.timestamp
        )
        self.last = smoothed
        return smoothed
    }

    private mutating func reject() -> CLLocation? { consecutiveRejects += 1; return nil }
}

// MARK: - Off-route detection

/// Decides "the user has left the route" from distance-to-route, with a threshold that follows the
/// fix's own accuracy: tight on a good fix (so a wrong turn is noticed within a couple of seconds),
/// looser on a poor one (so noise does not trigger a reroute on the right road).
struct OffRouteDetector {
    enum Mode { case walking, vehicle }
    private(set) var streak = 0

    static func threshold(mode: Mode, accuracy: Double) -> Double {
        switch mode {
        case .walking: return min(45, 20 + accuracy)
        case .vehicle: return min(70, 30 + accuracy)
        }
    }

    /// Feed one fix. Returns true once the user should be considered off route.
    mutating func update(distanceFromRoute: Double, accuracy: Double, mode: Mode) -> Bool {
        // A fix this poor says nothing either way — keep the streak, do not add to it.
        guard accuracy >= 0, accuracy <= 50 else { return streak >= 2 }
        let limit = Self.threshold(mode: mode, accuracy: accuracy)
        if distanceFromRoute > limit {
            // Far beyond the limit on a good fix is unmistakable: one fix is enough.
            streak += distanceFromRoute > limit * 2.5 && accuracy <= 25 ? 2 : 1
        } else {
            streak = 0
        }
        return streak >= 2
    }

    mutating func reset() { streak = 0 }
}

// MARK: - Remaining time

enum NavETA {
    /// Seconds left. Scales the route's own expected time by the share of the route still ahead, so
    /// it counts down with real progress; while driving, the current speed nudges it (bounded, so a
    /// red light or a burst of speed does not swing the number wildly).
    static func remainingSeconds(remainingMeters: Double, routeMeters: Double, routeSeconds: Double,
                                 speed: Double?, vehicle: Bool) -> Double {
        guard routeMeters > 0, routeSeconds > 0 else { return 0 }
        let planned = routeSeconds * min(1, max(0, remainingMeters / routeMeters))
        guard vehicle, let speed, speed >= 3 else { return planned }
        let live = remainingMeters / speed
        let bounded = min(planned * 2, max(planned * 0.5, live))
        return planned * 0.7 + bounded * 0.3
    }
}

// MARK: - Voice pacing

enum SpeechPriority: Int, Comparable {
    case low = 0        // distance milestones
    case normal = 1     // maneuvers, start, waypoints
    case high = 2       // off route, reroute, arrival, speed cameras
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Decides whether an announcement may be spoken now. Every announcement used to be queued
/// blindly, so several arrived back to back and were read out late (a "前方 50 公尺" spoken after the
/// turn). Now: identical text is not repeated, a more important message interrupts a less important
/// one, low-priority milestones never queue behind anything, and a message that has to wait keeps
/// only the latest.
struct SpeechGate {
    enum Action: Equatable {
        case speakNow
        case interruptThenSpeak
        case queueLatest      // wait for the current utterance to end (replace any waiting one)
        case skip
    }

    static let repeatWindow: TimeInterval = 10
    static let queueMaxAge: TimeInterval = 6

    private var lastText: String?
    private var lastAt = Date.distantPast
    private var speaking: SpeechPriority?

    mutating func decide(_ text: String, priority: SpeechPriority, now: Date) -> Action {
        if text == lastText, now.timeIntervalSince(lastAt) < Self.repeatWindow { return .skip }
        guard let current = speaking else {
            markSpoken(text, priority, now); return .speakNow
        }
        if priority > current { markSpoken(text, priority, now); return .interruptThenSpeak }
        if priority == .low { return .skip }
        return .queueLatest
    }

    /// The speaker started something it had queued.
    mutating func markSpoken(_ text: String, _ priority: SpeechPriority, _ now: Date) {
        lastText = text; lastAt = now; speaking = priority
    }
    mutating func finished() { speaking = nil }
}

// MARK: - Info panel stability

/// What the bottom panel shows, kept calm. The raw numbers change every GPS fix (about once a second): distance by 15 m
/// each time, the countdown by a second, speed by a km/h — so the panel flickered. Now distance is rounded to a
/// sensible step, the countdown is in minutes (seconds only in the last minute and a half), speed is smoothed, and
/// nothing on screen changes more often than every couple of seconds — unless something real happened (a big jump,
/// a reroute), which shows at once.
struct NavPanel {
    struct Snapshot: Equatable {
        var distanceMeters: Int
        var etaSeconds: Int
        var speedKmh: Int?
    }

    static let minInterval: TimeInterval = 2.0
    private(set) var shown: Snapshot?
    private var changedAt: Date?
    private var speedEMA: Double?

    /// Distance shown to the driver: 10 m steps up close, 50 m steps to 1 km, 100 m steps beyond.
    static func roundedDistance(_ meters: Double) -> Int {
        let m = max(0, meters)
        if m < 200 { return Int((m / 10).rounded()) * 10 }
        if m < 1000 { return Int((m / 50).rounded()) * 50 }
        return Int((m / 100).rounded()) * 100
    }

    /// Countdown in whole minutes (rounded up: "1 分" until you are there); in the last 90 s, 5-second steps.
    static func roundedETA(_ seconds: Double) -> Int {
        let s = max(0, seconds)
        if s < 90 { return Int((s / 5).rounded(.up)) * 5 }
        return Int((s / 60).rounded(.up)) * 60
    }

    static func distanceText(_ meters: Int) -> String { meters < 1000 ? "\(meters) 公尺" : String(format: "%.1f 公里", Double(meters) / 1000) }

    static func etaText(_ seconds: Int) -> String {
        if seconds < 90 { return seconds <= 0 ? "即將抵達" : "\(seconds) 秒" }
        let mins = seconds / 60
        return mins < 60 ? "\(mins) 分" : "\(mins / 60) 小時 \(mins % 60) 分"
    }

    /// Feed the raw values; returns what to display. `force` shows the new values immediately (reroute, new leg).
    @discardableResult
    mutating func update(distance: Double?, etaSeconds: Double?, speed: Double?, now: Date, force: Bool = false) -> Snapshot? {
        guard let distance else { return shown }
        if let speed, speed >= 0 { speedEMA = speedEMA.map { $0 * 0.7 + speed * 0.3 } ?? speed } else { speedEMA = nil }
        let candidate = Snapshot(
            distanceMeters: Self.roundedDistance(distance),
            etaSeconds: etaSeconds.map(Self.roundedETA) ?? shown?.etaSeconds ?? 0,
            speedKmh: speedEMA.map { Int(($0 * 3.6).rounded()) }
        )
        guard let current = shown, let at = changedAt else { shown = candidate; changedAt = now; return candidate }
        if candidate == current { return current }

        // A real change shows at once: a big jump in distance (reroute, new leg, a wrong turn), or arriving.
        let jump = abs(candidate.distanceMeters - current.distanceMeters)
        let big = force || jump > max(100, current.distanceMeters / 4) || candidate.distanceMeters <= 30
        if big || now.timeIntervalSince(at) >= Self.minInterval {
            shown = candidate; changedAt = now
        }
        return shown
    }

    mutating func reset() { shown = nil; changedAt = nil; speedEMA = nil }
}
