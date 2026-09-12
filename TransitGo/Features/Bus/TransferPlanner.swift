import Foundation
import CoreLocation

/// One ride on one bus route/direction, from `boardStop` to `alightStop`.
struct TransferLeg: Identifiable, Hashable {
    let id = UUID()
    let scope: BusScope
    let routeName: String
    let direction: Int
    let boardStop: BusRouteStop
    let alightStop: BusRouteStop

    static func == (l: TransferLeg, r: TransferLeg) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A full trip: one leg (direct) or two (a single transfer).
struct TransferItinerary: Identifiable {
    let id = UUID()
    let legs: [TransferLeg]
    var isDirect: Bool { legs.count == 1 }
}

/// `itineraries` empty AND `hadNetworkError` true means "TDX didn't actually answer" —
/// very different from "TDX answered and there's genuinely no route" (`hadNetworkError`
/// false), and the UI should say so rather than implying no service exists.
struct TransferPlanResult {
    let itineraries: [TransferItinerary]
    let hadNetworkError: Bool
}

/// A single-transfer bus trip planner over TDX data — not a real optimizer (no schedule
/// timing, no walking-distance minimization, no multi-modal), just: is there a route that
/// goes straight there, and if not, is there a stop where one route's path crosses
/// another's that gets you the rest of the way? Good enough for "which bus, transfer
/// where" — the everyday question, not turn-by-turn trip planning.
enum TransferPlanner {
    private struct Leg {
        let routeName: String
        let direction: Int
        let stops: [BusRouteStop]   // ordered by sequence
    }

    private struct ScopeResult {
        var direct: [TransferItinerary] = []
        var transfers: [TransferItinerary] = []
        var hadError = false
    }

    /// City bus AND intercity coach (公路客運) routes both get searched — a stop like
    /// 新竹縣政府 is served by both, and a route like 5900 (新竹縣政府↔高鐵新竹站) lives
    /// under `.interCity`, not any single county, so scoping to just the resolved city
    /// alone would silently miss it.
    static func plan(city: BusCity, from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> TransferPlanResult {
        let scopes: [BusScope] = [.city(city), .interCity]
        var direct: [TransferItinerary] = []
        var transfers: [TransferItinerary] = []
        var hadError = false

        // Each scope's stop/route IDs live in their own namespace, so both the direct-route
        // search and the same-scope transfer search run independently per scope; a transfer
        // *between* a city bus and an intercity coach isn't attempted — there's no shared
        // stop-ID key to detect where their paths would actually cross.
        await withTaskGroup(of: ScopeResult.self) { group in
            for scope in scopes {
                group.addTask { await planWithinScope(scope, from: origin, to: destination) }
            }
            for await result in group {
                direct += result.direct
                transfers += result.transfers
                if result.hadError { hadError = true }
            }
        }
        let itineraries = !direct.isEmpty ? Array(direct.prefix(5)) : Array(transfers.prefix(5))
        return TransferPlanResult(itineraries: itineraries, hadNetworkError: hadError && itineraries.isEmpty)
    }

    private static func planWithinScope(
        _ scope: BusScope, from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async -> ScopeResult {
        async let originStopsTask = nearbyStopUIDs(scope: scope, at: origin)
        async let destStopsTask = nearbyStopUIDs(scope: scope, at: destination)
        let (originStopUIDs, originFailed) = await originStopsTask
        let (destStopUIDs, destFailed) = await destStopsTask
        guard !originStopUIDs.isEmpty, !destStopUIDs.isEmpty else {
            return ScopeResult(hadError: originFailed || destFailed)
        }

        async let originRouteNamesTask = routeNames(scope: scope, stopUIDs: originStopUIDs)
        async let destRouteNamesTask = routeNames(scope: scope, stopUIDs: destStopUIDs)
        let (originRouteNames, originNamesFailed) = await originRouteNamesTask
        let (destRouteNames, destNamesFailed) = await destRouteNamesTask
        guard !originRouteNames.isEmpty, !destRouteNames.isEmpty else {
            return ScopeResult(hadError: originNamesFailed || destNamesFailed)
        }

        // Cap candidates so this stays a handful of TDX calls, not dozens.
        async let originLegsTask = usableLegs(scope: scope, routeNames: Array(originRouteNames.prefix(6)))
        async let destLegsTask = usableLegs(scope: scope, routeNames: Array(destRouteNames.prefix(6)))
        let originLegs = await originLegsTask
        let destLegs = await destLegsTask

        var direct: [TransferItinerary] = []
        var transfers: [TransferItinerary] = []

        for o in originLegs {
            guard let boardIdx = o.stops.firstIndex(where: { originStopUIDs.contains($0.stopUID) }) else { continue }

            // Direct: same route+direction also touches a destination stop, later in the list.
            if let alightIdx = o.stops.indices.first(where: { $0 > boardIdx && destStopUIDs.contains(o.stops[$0].stopUID) }) {
                direct.append(TransferItinerary(legs: [TransferLeg(
                    scope: scope, routeName: o.routeName, direction: o.direction,
                    boardStop: o.stops[boardIdx], alightStop: o.stops[alightIdx]
                )]))
                continue   // this route already gets there directly — don't also suggest transferring off it
            }

            // Transfer: find a dest-bound route (same scope) whose path crosses this one further along.
            let remaining = o.stops[(boardIdx + 1)...]
            for d in destLegs where d.routeName != o.routeName {
                guard let alightIdx = d.stops.firstIndex(where: { destStopUIDs.contains($0.stopUID) }) else { continue }
                let reachable = d.stops[..<alightIdx]   // stops on the dest leg before the alight point
                guard let transferStop = remaining.first(where: { rs in reachable.contains(where: { $0.stopUID == rs.stopUID }) })
                else { continue }
                guard let transferIdxOnDest = d.stops.firstIndex(where: { $0.stopUID == transferStop.stopUID }) else { continue }
                transfers.append(TransferItinerary(legs: [
                    TransferLeg(scope: scope, routeName: o.routeName, direction: o.direction, boardStop: o.stops[boardIdx], alightStop: transferStop),
                    TransferLeg(scope: scope, routeName: d.routeName, direction: d.direction, boardStop: d.stops[transferIdxOnDest], alightStop: d.stops[alightIdx]),
                ]))
                break   // one transfer option per origin route is plenty
            }
        }

        return ScopeResult(direct: direct, transfers: transfers)
    }

    // MARK: - Helpers

    /// Returns `(stopUIDs, failed)` — `failed` is true only when the TDX request itself
    /// errored (rate limit, network), distinct from a *successful* empty response.
    private static func nearbyStopUIDs(scope: BusScope, at coord: CLLocationCoordinate2D, radius: Int? = nil) async -> (Set<String>, Bool) {
        // Intercity coach stops sit further apart than city stops, and a landmark search
        // (e.g. "高鐵新竹站" resolved via MapKit) can land tens/hundreds of metres from
        // where the actual bus stop pole is — a tight radius silently misses real matches.
        let effectiveRadius = radius ?? (scope == .interCity ? 900 : 500)
        do {
            let raw: [NearbyStop] = try await TDXClient.shared.get(
                "v2/Bus/Stop/\(scope.pathComponent)",
                query: [
                    "$spatialFilter": "nearby(\(coord.latitude),\(coord.longitude),\(effectiveRadius))",
                    "$select": "StopUID,StopName,StopPosition",
                    "$top": "40",
                ]
            )
            return (Set(raw.map(\.stopUID)), false)
        } catch {
            return ([], true)
        }
    }

    /// Distinct route names currently serving any of these stops, plus whether the
    /// request itself failed.
    private static func routeNames(scope: BusScope, stopUIDs: Set<String>) async -> ([String], Bool) {
        do {
            let arrivals = try await BusService.shared.arrivals(scope: scope, stopUIDs: Array(stopUIDs))
            var seen = Set<String>()
            var out: [String] = []
            for a in arrivals where seen.insert(a.routeName).inserted { out.append(a.routeName) }
            return (out, false)
        } catch {
            return ([], true)
        }
    }

    private static func usableLegs(scope: BusScope, routeNames: [String]) async -> [Leg] {
        await withTaskGroup(of: [Leg].self) { group in
            for name in routeNames {
                group.addTask {
                    guard let dirs = try? await BusService.shared.directions(scope: scope, routeName: name) else { return [] }
                    return dirs.map { Leg(routeName: name, direction: $0.direction, stops: $0.stops) }
                }
            }
            var out: [Leg] = []
            for await legs in group { out += legs }
            return out
        }
    }
}
