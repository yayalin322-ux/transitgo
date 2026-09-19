import Foundation
import CoreLocation
import SwiftData

// MARK: - Value types (what planning and views work with)

/// What kind of place an endpoint is. The display name is NEVER the identity: a stop/station is
/// identified by (kind, refId), an address/POI by its coordinate.
enum TripEndpointKind: String, Codable, CaseIterable {
    case address, poi, busStop, mrtStation, traStation, hsrStation, bikeStation
    /// "Wherever I am when I open it" — resolved to the device location at planning time, so a
    /// favorite like 目前位置 → 學校 keeps working from any place. No stored coordinate.
    case currentLocation
}

/// How the user wants results ordered. Maps 1:1 to the routing engine's profiles (`label` is the
/// ranking label its results carry). `lowestCost` exists in the model so a future fare source needs no
/// migration, but is NOT offered today: the engine has no fare data, so nothing can honestly be "cheapest".
enum TripProfile: String, Codable, CaseIterable, Identifiable {
    case fastest, balanced, fewestTransfers, leastWalking, lowestCost
    var id: String { rawValue }

    /// The label the routing engine puts on a result produced by this profile.
    var engineLabel: String {
        switch self {
        case .fastest: return "最快"
        case .balanced: return "最均衡"
        case .fewestTransfers: return "少轉乘"
        case .leastWalking: return "少走路"
        case .lowestCost: return "最便宜"
        }
    }
    var title: String {
        switch self {
        case .fastest: return "最快"
        case .balanced: return "最平衡"
        case .fewestTransfers: return "少轉乘"
        case .leastWalking: return "少走路"
        case .lowestCost: return "最低票價（目前無完整票價資料）"
        }
    }
    /// False while there is no real fare source — the picker shows it disabled instead of pretending.
    static var lowestCostAvailable: Bool { false }
    var isSelectable: Bool { self != .lowestCost || Self.lowestCostAvailable }
}

/// One end of a trip. Value type, no SwiftData — what the planner, the editor and the tests pass around.
struct TripEndpoint: Codable, Equatable {
    var name: String
    var kind: TripEndpointKind
    /// Stop/station id for the kinds that have one (TDX StopUID, station id, bike station id).
    var refId: String?
    var latitude: Double
    var longitude: Double

    static let currentLocation = TripEndpoint(name: "目前位置", kind: .currentLocation, refId: nil, latitude: 0, longitude: 0)

    init(name: String, kind: TripEndpointKind, refId: String? = nil, latitude: Double, longitude: Double) {
        self.name = name; self.kind = kind; self.refId = refId; self.latitude = latitude; self.longitude = longitude
    }
    init(name: String, kind: TripEndpointKind, refId: String? = nil, coordinate: CLLocationCoordinate2D) {
        self.init(name: name, kind: kind, refId: refId, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var isCurrentLocation: Bool { kind == .currentLocation }

    /// A usable place: a real coordinate inside Taiwan (incl. outlying islands), or "current location".
    /// Used to refuse a corrupted/zeroed favorite before it reaches the router.
    var hasValidCoordinate: Bool {
        if isCurrentLocation { return true }
        return latitude.isFinite && longitude.isFinite && (21.5...26.5).contains(latitude) && (118.0...123.0).contains(longitude)
    }

    /// Identity for de-duplication: never the display name.
    var key: String {
        switch kind {
        case .currentLocation: return "current"
        case .busStop, .mrtStation, .traStation, .hsrStation, .bikeStation:
            if let refId, !refId.isEmpty { return "\(kind.rawValue):\(refId)" }
            fallthrough
        case .address, .poi:
            return String(format: "geo:%.4f,%.4f", latitude, longitude)   // ~10 m
        }
    }

    var emoji: String {
        switch name {
        case "家", "住家": return "🏠"
        case "學校": return "🏫"
        case "公司": return "🏢"
        default: break
        }
        switch kind {
        case .currentLocation: return "📍"
        case .busStop: return "🚏"
        case .mrtStation, .traStation, .hsrStation: return "🚉"
        case .bikeStation: return "🚲"
        case .address, .poi: return "📌"
        }
    }
}

/// Quick names offered when saving a place — never a restriction (any text is fine).
enum TripNamePreset: String, CaseIterable, Identifiable {
    case home = "家", school = "學校", work = "公司", other = "其他"
    var id: String { rawValue }
}

/// Origin + destination + preference: everything needed to plan, nothing that goes stale.
struct TripSpec: Equatable {
    var origin: TripEndpoint
    var destination: TripEndpoint
    var profile: TripProfile = .fastest

    /// ⇅ — swaps the two ends (the preference stays).
    var reversed: TripSpec { TripSpec(origin: destination, destination: origin, profile: profile) }
    var isValid: Bool { origin.hasValidCoordinate && destination.hasValidCoordinate && origin.key != destination.key && !(origin.isCurrentLocation && destination.isCurrentLocation) }
    /// Same trip regardless of preference or display names.
    var identity: String { "\(origin.key)>\(destination.key)" }
}

// MARK: - SwiftData models

/// A saved journey: WHERE FROM and WHERE TO, plus how the user likes results ordered. It never holds a
/// route — routes are recomputed (with realtime) every time it is opened. Flat columns, not a nested
/// struct, so the store stays simple to migrate and query.
@Model
final class FavoriteTrip {
    @Attribute(.unique) var id: UUID
    var name: String

    var originName: String
    var originKind: String
    var originRef: String?
    var originLat: Double
    var originLon: Double

    var destinationName: String
    var destinationKind: String
    var destinationRef: String?
    var destinationLat: Double
    var destinationLon: Double

    var preferredProfile: String
    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int

    // Reserved for later phases (scheduled departures). Stored, never read or set yet.
    var scheduledDepartureSeconds: Int?
    var daysOfWeekMask: Int?

    init(id: UUID = UUID(), name: String, spec: TripSpec, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.originName = spec.origin.name; self.originKind = spec.origin.kind.rawValue; self.originRef = spec.origin.refId
        self.originLat = spec.origin.latitude; self.originLon = spec.origin.longitude
        self.destinationName = spec.destination.name; self.destinationKind = spec.destination.kind.rawValue; self.destinationRef = spec.destination.refId
        self.destinationLat = spec.destination.latitude; self.destinationLon = spec.destination.longitude
        self.preferredProfile = spec.profile.rawValue
        self.createdAt = createdAt
        self.lastUsedAt = nil
        self.useCount = 0
    }

    var spec: TripSpec {
        get {
            TripSpec(
                origin: TripEndpoint(name: originName, kind: TripEndpointKind(rawValue: originKind) ?? .address, refId: originRef, latitude: originLat, longitude: originLon),
                destination: TripEndpoint(name: destinationName, kind: TripEndpointKind(rawValue: destinationKind) ?? .address, refId: destinationRef, latitude: destinationLat, longitude: destinationLon),
                profile: TripProfile(rawValue: preferredProfile) ?? .fastest
            )
        }
        set {
            originName = newValue.origin.name; originKind = newValue.origin.kind.rawValue; originRef = newValue.origin.refId
            originLat = newValue.origin.latitude; originLon = newValue.origin.longitude
            destinationName = newValue.destination.name; destinationKind = newValue.destination.kind.rawValue; destinationRef = newValue.destination.refId
            destinationLat = newValue.destination.latitude; destinationLon = newValue.destination.longitude
            preferredProfile = newValue.profile.rawValue
        }
    }
}

/// A journey the user searched recently (kept: at most `TripStore.maxRecents`). Same shape as a
/// favorite's endpoints; `searchCount` drives the "add to favorites?" suggestion.
@Model
final class RecentTrip {
    @Attribute(.unique) var id: UUID
    var identity: String
    var originName: String
    var originKind: String
    var originRef: String?
    var originLat: Double
    var originLon: Double
    var destinationName: String
    var destinationKind: String
    var destinationRef: String?
    var destinationLat: Double
    var destinationLon: Double
    var searchedAt: Date
    var searchCount: Int
    /// The user said "no thanks" to the suggestion for this journey — never ask again.
    var suggestionDismissed: Bool

    init(spec: TripSpec, at date: Date) {
        self.id = UUID()
        self.identity = spec.identity
        self.originName = spec.origin.name; self.originKind = spec.origin.kind.rawValue; self.originRef = spec.origin.refId
        self.originLat = spec.origin.latitude; self.originLon = spec.origin.longitude
        self.destinationName = spec.destination.name; self.destinationKind = spec.destination.kind.rawValue; self.destinationRef = spec.destination.refId
        self.destinationLat = spec.destination.latitude; self.destinationLon = spec.destination.longitude
        self.searchedAt = date
        self.searchCount = 1
        self.suggestionDismissed = false
    }

    var spec: TripSpec {
        TripSpec(
            origin: TripEndpoint(name: originName, kind: TripEndpointKind(rawValue: originKind) ?? .address, refId: originRef, latitude: originLat, longitude: originLon),
            destination: TripEndpoint(name: destinationName, kind: TripEndpointKind(rawValue: destinationKind) ?? .address, refId: destinationRef, latitude: destinationLat, longitude: destinationLon)
        )
    }
}
