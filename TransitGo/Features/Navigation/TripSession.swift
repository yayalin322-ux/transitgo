import Foundation
import CoreLocation

// MARK: - Geometry

struct TripCoordinate: Codable, Equatable {
    var lat: Double
    var lon: Double
    init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lon = c.longitude }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum TripGeometry {
    private static let earthRadius = 6_371_000.0

    static func distance(_ a: TripCoordinate, _ b: TripCoordinate) -> Double {
        let p = Double.pi / 180
        let dLat = (b.lat - a.lat) * p, dLon = (b.lon - a.lon) * p
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * p) * cos(b.lat * p) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Distance from `p` to the straight segment a–b (local flat projection: exact enough over a few km).
    static func distance(from p: TripCoordinate, toSegment a: TripCoordinate, _ b: TripCoordinate) -> Double {
        let p0 = Double.pi / 180
        let latScale = 111_320.0, lonScale = 111_320.0 * cos(a.lat * p0)
        func xy(_ c: TripCoordinate) -> (Double, Double) { ((c.lon - a.lon) * lonScale, (c.lat - a.lat) * latScale) }
        let (px, py) = xy(p), (bx, by) = xy(b)
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return hypot(px, py) }
        let t = max(0, min(1, (px * bx + py * by) / len2))
        return hypot(px - t * bx, py - t * by)
    }
}

// MARK: - A real location fix (never synthesized in app code)

/// One position reported by CoreLocation. `TripEngine` only ever receives these from the location
/// source (or from tests) — the app never invents a position.
struct TripFix: Codable, Equatable {
    var lat: Double
    var lon: Double
    /// Horizontal accuracy in metres; negative = invalid (CoreLocation's own convention).
    var accuracy: Double
    var timestamp: Date
    /// Metres/second, negative when unknown.
    var speed: Double

    var coordinate: TripCoordinate { TripCoordinate(lat: lat, lon: lon) }
    init(lat: Double, lon: Double, accuracy: Double, timestamp: Date, speed: Double = -1) {
        self.lat = lat; self.lon = lon; self.accuracy = accuracy; self.timestamp = timestamp; self.speed = speed
    }
    init(_ l: CLLocation) {
        self.init(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy, timestamp: l.timestamp, speed: l.speed)
    }
    /// Good enough to reason about position: valid and not wildly imprecise.
    var isUsable: Bool { accuracy >= 0 && accuracy <= TripPolicy.maxUsableAccuracy }
}

// MARK: - The plan being followed

enum TripLegKind: String, Codable {
    case walk, bus, metro, tra, hsr, bike, other
    init(mode: String) {
        switch mode {
        case "WALK": self = .walk
        case "BUS": self = .bus
        case "MRT", "METRO": self = .metro
        case "TRA": self = .tra
        case "HSR": self = .hsr
        case "BIKE": self = .bike
        default: self = .other
        }
    }
    var isVehicle: Bool { self == .bus || self == .metro || self == .tra || self == .hsr }
    /// Followed by GPS all the way (walking / cycling); a vehicle leg may run underground where there is no GPS.
    var isSelfPropelled: Bool { self == .walk || self == .bike }
}

/// One leg of the route being followed, copied out of the engine's `MultimodalSegment` so the navigation
/// logic never depends on the network model. Everything here is what the planner really returned.
struct TripLeg: Codable, Equatable, Identifiable {
    var index: Int
    var kind: TripLegKind
    /// "182" / "板南線" / "台鐵" / "高鐵" / "YouBike"; nil for a walk.
    var lineLabel: String?
    var towards: String?
    var fromName: String
    var toName: String
    var from: TripCoordinate?
    var to: TripCoordinate?
    var scheduledDeparture: Date
    var scheduledArrival: Date
    /// True when the times come from a real timetable (TRA/HSR trips); false for headway-based buses/metro,
    /// whose departure is an estimate — such a leg can never be "missed" by the clock.
    var isTimetabled: Bool
    var stopCount: Int
    var stopNames: [String]?
    /// Planner's own distance for the leg when it reports one (walk/bike); else straight line is used.
    var distanceMeters: Double?
    var walkKind: String?

    var id: Int { index }
    var durationSeconds: Int { max(0, Int(scheduledArrival.timeIntervalSince(scheduledDeparture))) }
    /// Best distance for "how far is this leg": the planner's, else the straight line between its ends.
    var length: Double {
        if let distanceMeters { return distanceMeters }
        if let from, let to { return TripGeometry.distance(from, to) }
        return 0
    }
}

struct TripPlan: Codable {
    var routeId: String
    var label: String
    var legs: [TripLeg]
    /// The route exactly as the planner returned it — kept so realtime can be asked about the SAME route.
    var route: MultimodalRoute
    var departure: Date
    var arrival: Date

    var totalDurationSeconds: Int { max(1, Int(arrival.timeIntervalSince(departure))) }

    init(route: MultimodalRoute) {
        self.route = route
        self.routeId = route.routeId
        self.label = route.label
        let iso = ISO8601DateFormatter()
        func date(_ s: String) -> Date { iso.date(from: s) ?? Date.distantPast }
        self.departure = date(route.departureTime)
        self.arrival = date(route.arrivalTime)
        self.legs = route.segments.enumerated().map { i, seg in
            let kind = TripLegKind(mode: seg.mode)
            // A walk/bike segment's real distance is on the matching engine leg.
            let engineLeg = route.legs.first { $0.from == seg.from && $0.mode == seg.mode }
            return TripLeg(
                index: i, kind: kind,
                lineLabel: kind == .walk ? nil : (seg.line ?? seg.routeShortName ?? seg.modeLabel),
                towards: seg.towards,
                fromName: seg.fromName ?? "", toName: seg.toName ?? "",
                from: seg.fromCoordinate.map(TripCoordinate.init), to: seg.toCoordinate.map(TripCoordinate.init),
                scheduledDeparture: date(seg.departureTime), scheduledArrival: date(seg.arrivalTime),
                isTimetabled: kind.isVehicle && !seg.isEstimated,
                stopCount: seg.stopsPassed,
                stopNames: seg.stops,
                distanceMeters: seg.reportedDistanceMeters ?? engineLeg?.distanceMeters,
                walkKind: seg.walkKind
            )
        }
    }
}

// MARK: - Session state

enum TripStatus: String, Codable {
    case notStarted, walkingToTransit, waitingForTransit, onTransit, ridingBike
    case transferring, walkingToDestination, arrived, paused, cancelled
}

/// Where a shown time / progress figure comes from — never dressed up as something better.
enum TripInfoSource: String, Codable { case realtime, schedule, gps, estimate }

enum TripRealtimeState: String, Codable {
    case notChecked
    /// Fresh data from the realtime service.
    case live
    /// Asked and could not get it (offline / service down): guidance falls back to the timetable.
    case unavailable
}

/// What the person should do now / next. Data only — the words live in `TripInstructionText`.
struct TripInstruction: Codable, Equatable {
    enum Kind: String, Codable {
        case walkTo, approaching, waitForVehicle, rideVehicle, prepareToAlight, transfer
        case rentBike, rideBike, returnBike, arrived, staticOverview
    }
    var kind: Kind
    var legIndex: Int
    var legKind: TripLegKind
    var lineLabel: String?
    var towards: String?
    var targetName: String?
    var distanceMeters: Double?
    var durationSeconds: Int?
    var stopsRemaining: Int?
    var stopsAreEstimated: Bool = false
    /// Metro-style rides with a station list: where the rider probably is / will be next (estimates).
    var currentStopName: String?
    var nextStopName: String?
    var time: Date?
    var delaySeconds: Int?
    var source: TripInfoSource = .schedule
}

/// "Change to 淡水信義線 at 台北車站" — data only.
struct TripTransfer: Codable, Equatable {
    var legIndex: Int
    var lineLabel: String?
    var legKind: TripLegKind
    var atName: String
}

struct TripSession: Codable, Identifiable {
    var tripId: UUID
    var routeId: String
    var origin: TripEndpoint
    var destination: TripEndpoint
    var startedAt: Date

    var plan: TripPlan
    var currentLegIndex: Int
    var status: TripStatus
    /// 0...1 over the whole trip, by time.
    var progress: Double

    /// The last REAL fix received; nil until one arrives — never a guess.
    var currentLocation: TripFix?
    var remainingDistanceMeters: Double?
    var remainingDurationSeconds: Int?

    var current: TripInstruction?
    var nextAction: TripInstruction?
    var nextStop: String?
    var nextTransfer: TripTransfer?

    // Progress inside the current leg (persisted so a relaunch resumes exactly here).
    var legEnteredAt: Date
    /// When the rider got on the vehicle (or rented the bike); nil while still waiting / walking to it.
    var boardedAt: Date?
    var boardedWasInferred = false
    /// One-shot notices already given ("approaching:3", "transfer:3", ...), so nothing repeats.
    var announced: Set<String> = []

    var lastUpdatedAt: Date

    // Live conditions
    var realtime: TripRealtimeState = .notChecked
    var realtimeUpdatedAt: Date?
    /// Real delay (seconds) for legs on a real timetable (TRA/HSR) — from the realtime service only.
    var delayByLeg: [Int: Int] = [:]
    /// Realtime estimate of when a headway-based vehicle reaches the boarding stop.
    var etaByLeg: [Int: Date] = [:]
    var cancelledLegs: Set<Int> = []
    var isOffline = false
    /// False = the user has not allowed location: the trip can be read but never followed.
    var locationAuthorized = true
    var reroutes = 0

    var id: UUID { tripId }
    var currentLeg: TripLeg? { plan.legs.indices.contains(currentLegIndex) ? plan.legs[currentLegIndex] : nil }
    var isFinished: Bool { status == .arrived || status == .cancelled }
}

// MARK: - Events

enum TripEvent: Equatable {
    case started(routeId: String)
    case legChanged(from: Int, to: Int)
    case approachingStop(legIndex: Int, name: String)
    case arrivedAtStation(legIndex: Int, name: String, inferredFromSchedule: Bool)
    case transferRequired(fromLeg: Int, toLeg: Int, name: String)
    case boarded(legIndex: Int, inferred: Bool)
    case delayed(legIndex: Int, seconds: Int)
    case offRoute(legIndex: Int, distanceMeters: Double)
    case missedDeparture(legIndex: Int)
    case rerouteSuggested(reason: RerouteReason)
    case rerouted(reason: RerouteReason)
    case realtimeUnavailable
    case offline
    case backOnline
    case completed
    case cancelled

    /// Something worth interrupting the user for (banner/haptic). Silent bookkeeping events are false.
    var isAlert: Bool {
        switch self {
        case .approachingStop, .arrivedAtStation, .transferRequired, .delayed, .missedDeparture, .rerouted, .rerouteSuggested, .completed, .offline: return true
        default: return false
        }
    }
}

enum RerouteReason: String, Codable, Equatable { case offRoute, missedDeparture, severeDelay, cancelled, requestedByUser }

// MARK: - Every number the navigation logic uses

enum TripPolicy {
    /// A fix worse than this is not used to decide anything (CoreLocation reports 65 m for a poor Wi-Fi fix).
    static let maxUsableAccuracy = 100.0

    // Arrival radii (metres) by what is being arrived at, before the accuracy allowance below.
    static let destinationRadius = 40.0
    static let stopRadius = 50.0
    static let stationRadius = 70.0
    static let bigStationRadius = 150.0        // 台鐵 / 高鐵 station grounds
    static let dockRadius = 50.0
    /// The radius is widened by half the fix's accuracy, capped, so a 30 m-accurate fix isn't held to a 40 m radius blindly.
    static let maxAccuracyAllowance = 30.0
    /// Fixes in a row that must be inside the radius (GPS noise: one lucky fix is not arrival).
    static let arrivalConfirmations = 2
    /// ...or one fix this well inside the radius.
    static let confidentArrivalAccuracy = 25.0
    static let approachingWalkDistance = 50.0
    static let approachingBikeDistance = 100.0
    static let approachingVehicleDistance = 500.0
    static let approachingVehicleSeconds = 120.0

    // Boarding / riding
    static let boardedAwayDistance = 120.0
    static let boardedSpeed = 3.0              // m/s: faster than anyone walks
    static let freshFixSeconds = 30.0          // a fix older than this is not "where the rider is"
    static let gpsLostSeconds = 90.0           // waiting at a stop with no usable fix this long past departure => underground / on board
    static let alightGraceSeconds = 60.0
    static let scheduleAdvanceMaxDistance = 800.0   // don't advance by clock while GPS says you're still far from the alight point

    // Off route (metres from the leg's own line) — by what the leg is; sustained for `offRouteConfirmations` fixes.
    static let offRouteWalk = 200.0
    static let offRouteBike = 350.0
    static let offRouteWaiting = 300.0
    static let offRouteVehicleFloor = 1_500.0
    static let offRouteVehicleFraction = 0.6
    static let offRouteConfirmations = 3
    static let offRouteMinSeconds = 20.0

    // Timing
    static let missedDepartureGrace = 120.0
    static let delayAlertSeconds = 180
    static let delayRealertChange = 120
    static let severeDelaySeconds = 900
    static let staleAfterHours = 12.0

    // Reroute pacing: never on every fix.
    static let rerouteCooldownSeconds = 90.0
    static let rerouteMinMovementMeters = 100.0
    static let maxAutoReroutesPer10Min = 3
    static let realtimeRefreshSeconds = 30.0
}
