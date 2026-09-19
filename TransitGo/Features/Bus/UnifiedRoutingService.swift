import Foundation
import CoreLocation

/// A single mode a `RouteResult` leg can be in — normalizes each planner's own mode
/// vocabulary (multimodal's raw `"BUS"`/`"TRA"`/`"METRO"`/`"WALK"` strings, the legacy bus
/// planner's implicit "riding a bus", the legacy metro planner's implicit "riding a
/// train") into one shared type so a single UI can render any of them.
enum RouteTransportMode: String {
    case walk, bus, metro, tra, hsr, bike, unknown

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .bus: return "bus.fill"
        case .metro: return "tram.fill.tunnel"
        case .tra: return "tram.fill"
        case .hsr: return "tram.fill"
        case .bike: return "bicycle"
        case .unknown: return "arrow.forward"
        }
    }

    init(multimodalMode: String) {
        switch multimodalMode {
        case "WALK": self = .walk
        case "BUS": self = .bus
        case "METRO": self = .metro
        case "TRA": self = .tra
        case "HSR": self = .hsr
        case "BIKE": self = .bike
        default: self = .unknown
        }
    }
}

/// One boarding/walk within a `RouteResult` — deliberately a plain, mode-agnostic shape
/// (not `MultimodalSegment`/`TransferLeg`/`MetroLeg` themselves) so a single `ForEach` can
/// render a leg regardless of which underlying planner produced it.
struct RouteResultLeg: Identifiable {
    let id = UUID()
    let mode: RouteTransportMode
    /// Real route/line display name (e.g. "20", "5900", "板南線") — nil for a WALK leg.
    let routeName: String?
    let fromName: String?
    let toName: String?
    /// "HH:mm" — nil where the source planner has no real schedule data for this leg
    /// (the legacy bus/metro planners don't; the multimodal engine does).
    let departureClock: String?
    let arrivalClock: String?
}

/// Which planner actually produced this candidate — kept so the UI can label a result's
/// data quality honestly (the multimodal engine has real schedule/fare/duration data;
/// the legacy planners only know "board here, alight here", nothing more).
enum RouteResultSource {
    case multimodalEngine
    case legacyBus
    case legacyMetro
}

/// The one shape every route-planning UI in the app should render from, regardless of
/// which planner(s) produced it. Real, verified data only: `durationSeconds`/`transfers`/
/// `walkingDistanceMeters`/`fare` are nil wherever the source planner genuinely doesn't
/// know them — never a guessed or zeroed-out placeholder (a legacy bus/metro result has
/// no real duration or fare data at all today, so those fields stay nil, and the UI must
/// show "資料暫無" rather than inventing "0"/"NT$0").
struct RouteResult: Identifiable {
    let id = UUID()
    /// The engine's own real ranking label ("最快"/"最均衡"/"少轉乘"/"少走路") for a
    /// multimodal result; a fixed, honest description ("公車" / "捷運") for a legacy one —
    /// never a fabricated ranking claim for data that was never actually ranked.
    let summary: String
    let legs: [RouteResultLeg]
    let transportModes: [RouteTransportMode]
    let departure: Date?
    let arrival: Date?
    let durationSeconds: Int?
    let transfers: Int?
    let walkingDistanceMeters: Double?
    /// nil = genuinely unknown — never 0 standing in for "unknown" (see astar.mjs on the
    /// backend: a route's fare is only ever a real number when every leg's price is
    /// actually known).
    let fare: Int?
    /// Live delay/cancellation status — not implemented yet (Phase 10, TDX realtime).
    /// Always nil today; the field exists now so that phase doesn't need a new type.
    let realtimeStatus: String?
    let source: RouteResultSource
}

/// The single facade every "plan a trip from A to B" call in the app should go through —
/// no View or ViewModel should itself decide which planner to call, how many times, how
/// to fall back, or how to stitch multiple planners' results together; that all happens
/// here, once, and every caller gets back one `[RouteResult]` list.
///
/// This is a migration step, not a rewrite: `TransferPlanner`, `MultimodalRoutingService`,
/// and `MetroTransferPlanner` are all still here, still real, still doing the actual
/// planning work. This only centralizes the *orchestration and normalization* — running
/// them, and turning their three different result shapes into one — into a single named,
/// testable place.
enum UnifiedRoutingService {
    struct Result {
        /// The unified, mode-agnostic list every route-results UI should render from.
        /// Multimodal-engine results (real duration/fare/schedule data) are sorted by
        /// real duration first; legacy bus/metro results (no duration data to sort by)
        /// follow in whatever order their own planner returned them.
        var routes: [RouteResult] = []
        /// True once every planner that could plausibly answer has come back empty —
        /// the point at which a caller should fall back to drive/walk/bike estimates.
        var isEmpty: Bool { routes.isEmpty }

        // Raw per-planner results, kept alongside `routes` only so existing type-specific
        // UI (rendering a MultimodalRoute's real modeIcon/fareText/segments, or a
        // TransferLeg's board/alight stops) keeps working during the migration to a
        // fully unified results view (Phase 6). New UI should prefer `routes`. These are
        // never independently fetched by a caller — populated once, here, from the same
        // three calls that produced `routes`.
        var multimodalRoutes: [MultimodalRoute] = []
        var multimodalStatus: MultimodalRoutingOutcome?
        var busItineraries: [TransferItinerary] = []
        var busHadNetworkError = false
        var metroItineraries: [MetroItinerary] = []
    }

    /// Runs every planner that could plausibly answer for this origin/destination in
    /// parallel, and returns ONE normalized result list. Callers that only want one
    /// specific planner's own behavior (e.g. TRA's station-name-only search, which has no
    /// coordinate origin to give this function) should keep calling that service
    /// directly — this facade is for the shared "coordinate in, ranked options out" case.
    static func plan(
        city: BusCity,
        metroOperator: MetroOperator?,
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departureTime: Date = Date()
    ) async -> Result {
        async let busResult = TransferPlanner.plan(city: city, from: origin, to: destination)
        async let multimodalResult = MultimodalRoutingService.plan(from: origin, to: destination, departureTime: departureTime)
        async let metroResult: [MetroItinerary] = {
            guard let metroOperator else { return [] }
            return await MetroTransferPlanner.planNearby(operator: metroOperator, from: origin, to: destination)
        }()

        let bus = await busResult
        let multimodal = await multimodalResult
        let metro = await metroResult

        var result = Result()
        result.busItineraries = bus.itineraries
        result.busHadNetworkError = bus.hadNetworkError
        result.metroItineraries = metro
        result.multimodalStatus = multimodal

        var routes: [RouteResult] = []
        if case .success(let multimodalRoutes) = multimodal {
            result.multimodalRoutes = multimodalRoutes
            routes.append(contentsOf: multimodalRoutes.map(Self.normalize))
        }
        routes.append(contentsOf: bus.itineraries.map(Self.normalize))
        routes.append(contentsOf: metro.map(Self.normalize))

        result.routes = routes
        return result
    }

    // MARK: - Normalization (each planner's own shape -> RouteResult)

    private static let isoFormatter = ISO8601DateFormatter()

    private static func normalize(_ route: MultimodalRoute) -> RouteResult {
        let legs = route.segments.map { seg in
            RouteResultLeg(
                mode: RouteTransportMode(multimodalMode: seg.mode),
                routeName: seg.routeShortName ?? seg.routeId,
                fromName: seg.fromName,
                toName: seg.toName,
                departureClock: seg.departureClock,
                arrivalClock: seg.arrivalClock
            )
        }
        return RouteResult(
            summary: route.label,
            legs: legs,
            transportModes: Array(Set(legs.map(\.mode))).sorted { $0.rawValue < $1.rawValue },
            departure: isoFormatter.date(from: route.departureTime),
            arrival: isoFormatter.date(from: route.arrivalTime),
            durationSeconds: route.durationSeconds,
            transfers: route.transfers,
            walkingDistanceMeters: route.walkingDistanceMeters,
            fare: route.fare,
            realtimeStatus: nil,
            source: .multimodalEngine
        )
    }

    private static func normalize(_ itinerary: TransferItinerary) -> RouteResult {
        let legs = itinerary.legs.map { leg in
            RouteResultLeg(
                mode: .bus,
                routeName: leg.routeName,
                fromName: leg.boardStop.stopName.display,
                toName: leg.alightStop.stopName.display,
                departureClock: nil,
                arrivalClock: nil
            )
        }
        return RouteResult(
            summary: itinerary.isDirect ? "公車直達" : "公車轉乘",
            legs: legs,
            transportModes: [.bus],
            departure: nil,
            arrival: nil,
            durationSeconds: nil,
            transfers: itinerary.isDirect ? 0 : 1,
            walkingDistanceMeters: nil,
            fare: nil,
            realtimeStatus: nil,
            source: .legacyBus
        )
    }

    private static func normalize(_ itinerary: MetroItinerary) -> RouteResult {
        let legs = itinerary.legs.map { leg in
            RouteResultLeg(
                mode: .metro,
                routeName: leg.lineName,
                fromName: leg.fromStation.name,
                toName: leg.toStation.name,
                departureClock: nil,
                arrivalClock: nil
            )
        }
        return RouteResult(
            summary: "捷運",
            legs: legs,
            transportModes: [.metro],
            departure: nil,
            arrival: nil,
            durationSeconds: nil,
            transfers: max(0, itinerary.legs.count - 1),
            walkingDistanceMeters: nil,
            fare: nil,
            realtimeStatus: nil,
            source: .legacyMetro
        )
    }
}
