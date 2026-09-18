import Foundation
import CoreLocation

/// The single facade every "plan a trip from A to B" call in the app should go through,
/// instead of the UI itself orchestrating three separate planners (the actual state
/// before this file existed: TransferPlannerViewModel.planAll() called
/// TransferPlanner.plan() + MultimodalRoutingService.plan() + MetroTransferPlanner
/// directly, in parallel, and stitched the three result sets together inline).
///
/// This is step one of a migration, not a rewrite: TransferPlanner, MultimodalRoutingService
/// and MetroTransferPlanner are all still here, still real, still doing the actual work —
/// this only centralizes the *combining* logic into one named, testable place so a caller
/// asks one question ("what are my options?") instead of learning to orchestrate three
/// services and their three different result shapes itself. Nothing is deleted; nothing
/// currently calling the old services directly is forced to change.
enum UnifiedRoutingService {
    struct Result {
        /// Real, real-time-dependent A* results from the new engine — present wherever
        /// it's actually been ingested. Empty (not nil) when the engine has no data for
        /// this area; check `multimodalStatus` to tell that apart from a request failure.
        var multimodalRoutes: [MultimodalRoute] = []
        var multimodalStatus: MultimodalRoutingOutcome?
        /// Legacy single-transfer bus planner — TDX live-arrival based, not schedule-aware.
        var busItineraries: [TransferItinerary] = []
        var busHadNetworkError = false
        /// Legacy same-line-only metro planner.
        var metroItineraries: [MetroItinerary] = []

        /// True once every planner that has data to try has genuinely come back empty —
        /// the point at which a caller should fall back to drive/walk/bike estimates.
        var isEmpty: Bool { multimodalRoutes.isEmpty && busItineraries.isEmpty && metroItineraries.isEmpty }
    }

    /// Runs every planner that could plausibly answer for this origin/destination in
    /// parallel and returns one combined result. Callers that only want one specific
    /// planner's behavior (e.g. TRA's station-name-only search, which has no coordinate
    /// origin to give this function) should keep calling that service directly — this
    /// facade is for the shared "coordinate in, options out" case, not a mandate that
    /// literally every route lookup in the app must go through it.
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
        if case .success(let routes) = multimodal {
            result.multimodalRoutes = routes
        }
        return result
    }
}
