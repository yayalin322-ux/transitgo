import Foundation
import CoreLocation

enum TripSide { case origin, destination }

/// What happened when a saved/recent journey was planned again. Every case is a normal, expected
/// result to SHOW — none of them touches the saved favorite (a failed plan never deletes or edits it).
enum TripPlanOutcome {
    /// Routes found (static engine and/or legacy planners). Realtime is added afterwards, separately.
    case routes(UnifiedRoutingService.Result, preferredRouteId: String?)
    /// Planning worked, no feasible route right now.
    case noRoute
    /// The saved place can't be used any more (no stop/station near it, or unknown to the network).
    case endpointUnusable(TripSide)
    /// The journey starts/ends at "current location" and the device has none.
    case locationUnavailable
    /// The planner could not be reached (offline / rate limited): says nothing about routes.
    case networkProblem
    /// Origin and destination are the same place.
    case sameLocation

    /// Wording for the notice a screen shows. nil for `.routes`.
    var message: String? {
        switch self {
        case .routes: return nil
        case .noRoute: return "目前找不到可行路線"
        case .endpointUnusable(let side): return side == .origin ? "原收藏的起點已無法使用，請重新選擇" : "原收藏的目的地已無法使用，請重新選擇"
        case .locationUnavailable: return "需要目前位置才能規劃，請開啟定位"
        case .networkProblem: return "目前無法連線到路線服務，請稍後再試（你的收藏不會受影響）"
        case .sameLocation: return "起點與終點相同"
        }
    }
}

/// Re-plans a journey from what was SAVED (two places and a preference) against the CURRENT time,
/// through `UnifiedRoutingService` — never from a stored route. The planner and realtime steps are
/// injectable so this is testable without a network.
enum TripPlanner {
    typealias PlanFunction = (BusCity, MetroOperator?, CLLocationCoordinate2D, CLLocationCoordinate2D, Date) async -> UnifiedRoutingService.Result
    typealias RealtimeFunction = (UnifiedRoutingService.Result) async -> UnifiedRoutingService.Result

    static let livePlan: PlanFunction = { city, metro, origin, destination, when in
        await UnifiedRoutingService.plan(city: city, metroOperator: metro, from: origin, to: destination, departureTime: when)
    }
    static let liveRealtime: RealtimeFunction = { result in await UnifiedRoutingService.attachRealtime(to: result) }

    /// Plans `spec` for departure `now` (a favorite is always "leave now" for now). `currentLocation`
    /// stands in for a `.currentLocation` end. The bus city only feeds the legacy same-city bus planner —
    /// the multimodal engine is nationwide — so a missing region falls back to a fixed city and the
    /// legacy planner simply finds nothing.
    static func plan(
        _ spec: TripSpec, city: BusCity?, metroOperator: MetroOperator?, currentLocation: CLLocationCoordinate2D?,
        now: Date = Date(), planFunction: PlanFunction = livePlan
    ) async -> TripPlanOutcome {
        guard spec.origin.hasValidCoordinate else { return .endpointUnusable(.origin) }
        guard spec.destination.hasValidCoordinate else { return .endpointUnusable(.destination) }
        guard let origin = resolve(spec.origin, currentLocation: currentLocation) else { return .locationUnavailable }
        guard let destination = resolve(spec.destination, currentLocation: currentLocation) else { return .locationUnavailable }
        let result = await planFunction(city ?? .taipei, metroOperator, origin, destination, now)
        return outcome(from: result, profile: spec.profile)
    }

    static func resolve(_ endpoint: TripEndpoint, currentLocation: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        endpoint.isCurrentLocation ? currentLocation : endpoint.coordinate
    }

    /// Adds realtime to a planned result (best effort; failure leaves the static routes as they are).
    static func withRealtime(_ result: UnifiedRoutingService.Result, realtime: RealtimeFunction = liveRealtime) async -> UnifiedRoutingService.Result {
        await realtime(result)
    }

    /// Reads a planner result the way a person would: routes if any exist, otherwise WHY there are none.
    static func outcome(from result: UnifiedRoutingService.Result, profile: TripProfile) -> TripPlanOutcome {
        if !result.routes.isEmpty {
            return .routes(ordered(result, profile: profile), preferredRouteId: preferredRouteId(in: result, profile: profile))
        }
        switch result.multimodalStatus {
        case .serverError(let code, _):
            switch code {
            case "NO_ORIGIN_NEARBY": return .endpointUnusable(.origin)
            case "NO_DESTINATION_NEARBY", "UNKNOWN_DESTINATION": return .endpointUnusable(.destination)
            case "SAME_ORIGIN_DESTINATION": return .sameLocation
            default: return result.busHadNetworkError ? .networkProblem : .noRoute
            }
        case .unreachable:
            return .networkProblem
        default:
            return result.busHadNetworkError ? .networkProblem : .noRoute
        }
    }

    /// The route whose engine ranking label is the saved preference, if the engine produced one.
    /// (`lowestCost` never matches today: no fare data means the engine never hands out that label.)
    static func preferredRouteId(in result: UnifiedRoutingService.Result, profile: TripProfile) -> String? {
        result.multimodalRoutes.first { $0.label == profile.engineLabel }?.id
    }

    /// The saved preference goes first; the others follow in the engine's order (nothing is dropped).
    static func ordered(_ result: UnifiedRoutingService.Result, profile: TripProfile) -> UnifiedRoutingService.Result {
        guard let id = preferredRouteId(in: result, profile: profile) else { return result }
        var out = result
        out.multimodalRoutes = result.multimodalRoutes.filter { $0.id == id } + result.multimodalRoutes.filter { $0.id != id }
        if case .success = result.multimodalStatus { out.multimodalStatus = .success(out.multimodalRoutes) }
        out.routes = result.routes.filter { $0.multimodalRouteId == id } + result.routes.filter { $0.multimodalRouteId != id }
        return out
    }
}
