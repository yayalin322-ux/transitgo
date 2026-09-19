import Foundation
import CoreLocation
@testable import TransitGo

/// Builders for navigation tests. Positions are SYNTHETIC test inputs along real Taipei coordinates — they exist only
/// in tests; the app itself never fabricates a location.
enum Nav {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    struct Pt { var lat: Double; var lon: Double
        var coord: TripCoordinate { TripCoordinate(lat: lat, lon: lon) } }

    // A small real-world-shaped trip (Taipei): 家 → bus stop → bus → MRT interchange → MRT → walk to the destination.
    static let home = Pt(lat: 25.0330, lon: 121.5436)
    static let busStop = Pt(lat: 25.0348, lon: 121.5436)        // ~200 m north of home
    static let busAlight = Pt(lat: 25.0470, lon: 121.5170)      // ~3.2 km away
    static let mrtStation = Pt(lat: 25.0478, lon: 121.5170)     // ~90 m from the bus alight stop
    static let mrtAlight = Pt(lat: 25.0521, lon: 121.5436)      // ~2.7 km east
    static let dest = Pt(lat: 25.0530, lon: 121.5436)           // ~100 m from the last station

    static func lerp(_ a: Pt, _ b: Pt, _ t: Double) -> Pt { Pt(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t) }
    static func dist(_ a: Pt, _ b: Pt) -> Double { TripGeometry.distance(a.coord, b.coord) }
    /// A point `meters` short of `b` on the way from `a`.
    static func before(_ b: Pt, from a: Pt, meters: Double) -> Pt { lerp(b, a, min(1, meters / max(1, dist(a, b)))) }

    static func fix(_ p: Pt, at t: TimeInterval, accuracy: Double = 10, speed: Double = -1) -> TripFix {
        TripFix(lat: p.lat, lon: p.lon, accuracy: accuracy, timestamp: t0.addingTimeInterval(t), speed: speed)
    }
    static func at(_ t: TimeInterval) -> Date { t0.addingTimeInterval(t) }
    static let backendISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// JSON null for a missing value.
    private static func ns(_ v: Any?) -> Any { v ?? NSNull() }

    struct Seg {
        var mode: String; var from: Pt; var to: Pt; var fromName: String; var toName: String
        var dep: TimeInterval; var arr: TimeInterval
        var line: String? = nil; var towards: String? = nil
        var estimated = true; var stops = 1; var stopNames: [String]? = nil; var walkKind: String? = nil; var distance: Double? = nil
    }

    static func route(_ segs: [Seg], id: String = "R001", label: String = "最快") throws -> MultimodalRoute {
        // Exactly the backend's format (Date.toISOString): UTC with milliseconds.
        func iso(_ t: TimeInterval) -> String { Nav.backendISO.string(from: at(t)) }
        let segJSON: [[String: Any]] = segs.map { s in
            var d: [String: Any] = [
                "mode": s.mode, "routeId": NSNull(), "routeShortName": ns(s.line), "scopePath": NSNull(),
                "from": "N:\(s.fromName)", "to": "N:\(s.toName)", "tripId": NSNull(),
                "fromName": s.fromName, "toName": s.toName, "fromLat": s.from.lat, "fromLng": s.from.lon, "toLat": s.to.lat, "toLng": s.to.lon,
                "departureTime": iso(s.dep), "arrivalTime": iso(s.arr), "durationSeconds": Int(s.arr - s.dep),
                "stopsPassed": s.stops, "isEstimated": s.estimated,
                "line": s.mode == "MRT" ? ns(s.line) : NSNull(), "towards": ns(s.towards),
                "stops": ns(s.stopNames), "walkKind": ns(s.walkKind),
            ]
            if let dist = s.distance { d["distanceMeters"] = dist }
            return d
        }
        let legJSON: [[String: Any]] = segs.map { s in
            ["mode": s.mode, "routeId": NSNull(), "from": "N:\(s.fromName)", "to": "N:\(s.toName)", "departureTime": iso(s.dep), "arrivalTime": iso(s.arr),
             "durationSeconds": Int(s.arr - s.dep), "isEstimated": s.estimated, "distanceMeters": ns(s.distance)]
        }
        let start = segs.first!.dep, end = segs.last!.arr
        let obj: [String: Any] = [
            "routeId": id, "label": label, "durationSeconds": Int(end - start), "departureTime": iso(start), "arrivalTime": iso(end),
            "walkingSeconds": 300, "waitingSeconds": 0, "transitSeconds": 600, "transfers": 1, "fare": NSNull(), "walkingDistanceMeters": 500,
            "realtimeStatus": NSNull(), "legs": legJSON, "segments": segJSON,
        ]
        return try JSONDecoder().decode(MultimodalRoute.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    /// WALK → BUS → WALK(to MRT) → MRT → WALK
    static func walkBusMrtWalk() throws -> MultimodalRoute {
        try route([
            Seg(mode: "WALK", from: home, to: busStop, fromName: "家", toName: "北門站", dep: 0, arr: 150, distance: 200),
            Seg(mode: "BUS", from: busStop, to: busAlight, fromName: "北門站", toName: "台北車站(公車)", dep: 300, arr: 1200, line: "182", towards: "往台北車站", estimated: true, stops: 8),
            Seg(mode: "WALK", from: busAlight, to: mrtStation, fromName: "台北車站(公車)", toName: "台北車站(捷運)", dep: 1200, arr: 1260, distance: 90),
            Seg(mode: "MRT", from: mrtStation, to: mrtAlight, fromName: "台北車站(捷運)", toName: "南京復興", dep: 1380, arr: 1980, line: "板南線", towards: "往南港展覽館", estimated: true, stops: 5,
                stopNames: ["台北車站", "善導寺", "忠孝新生", "忠孝復興", "忠孝敦化", "南京復興"]),
            Seg(mode: "WALK", from: mrtAlight, to: dest, fromName: "南京復興", toName: "目的地", dep: 1980, arr: 2060, distance: 100),
        ])
    }

    static func session(_ route: MultimodalRoute, authorized: Bool = true, now: Date = t0) -> TripSession {
        TripEngine.makeSession(plan: TripPlan(route: route), origin: TripEndpoint(name: "家", kind: .address, latitude: home.lat, longitude: home.lon),
                               destination: TripEndpoint(name: "目的地", kind: .address, latitude: dest.lat, longitude: dest.lon), now: now, locationAuthorized: authorized)
    }

    static func overlay(legIndex: Int, mode: String, scheduled: TimeInterval, delaySeconds: Int?, estimated: TimeInterval?, state: String = "delayed") throws -> RealtimeOverlay {
        func iso(_ t: TimeInterval?) -> Any { t.map { ISO8601DateFormatter().string(from: at($0)) } ?? NSNull() }
        let status: [String: Any] = ["mode": mode, "routeId": NSNull(), "tripId": NSNull(), "vehicleId": NSNull(), "scheduledTime": iso(scheduled), "estimatedTime": iso(estimated),
                                     "delaySeconds": ns(delaySeconds), "state": state, "source": "test", "updatedAt": iso(0)]
        let obj: [String: Any] = [
            "generatedAt": iso(0),
            "legs": [["index": legIndex, "mode": mode, "routeName": NSNull(), "available": true, "reason": NSNull(), "status": status, "arrivals": [], "alerts": [],
                      "alertsAvailable": true, "scheduledTime": iso(scheduled), "estimatedTime": iso(estimated), "etaSource": "realtime"]],
            "eta": ["etaSource": "realtime", "estimatedArrivalTime": NSNull(), "shiftSeconds": NSNull(), "basedOnLeg": NSNull()],
            "summary": ["anyRealtime": true, "state": state, "delaySeconds": ns(delaySeconds), "alerts": [], "unavailableReasons": []],
        ]
        return try JSONDecoder().decode(RealtimeOverlay.self, from: JSONSerialization.data(withJSONObject: obj))
    }
}

// MARK: - Fakes for the service

@MainActor
final class FakeLocation: TripLocationSource {
    var authorization: CLAuthorizationStatus
    var onFix: ((CLLocation) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    private(set) var startCalls = 0, stopCalls = 0
    init(_ authorization: CLAuthorizationStatus = .authorizedWhenInUse) { self.authorization = authorization }
    func start() { startCalls += 1 }
    func stop() { stopCalls += 1 }
    func emit(_ f: TripFix) {
        onFix?(CLLocation(coordinate: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), altitude: 0, horizontalAccuracy: f.accuracy, verticalAccuracy: -1, course: -1, speed: f.speed, timestamp: f.timestamp))
    }
}

@MainActor
final class FakeReachability: TripReachability {
    var isOnline = true
    var onChange: ((Bool) -> Void)?
    func start() {}
    func stop() {}
    func set(_ online: Bool) { isOnline = online; onChange?(online) }
}

final class MemoryStore: TripSessionStoring {
    var saved: TripSession?
    private(set) var saves = 0
    func save(_ session: TripSession) { saved = session; saves += 1 }
    func load() -> TripSession? { saved }
    func clear() { saved = nil }
}

@MainActor
final class Clock { var now = Nav.t0 }
