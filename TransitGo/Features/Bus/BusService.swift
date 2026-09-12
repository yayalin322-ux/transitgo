import Foundation
import CoreLocation

/// A single direction of a route, with stops in order and ETA / live-bus overlays.
struct RouteDirection: Identifiable {
    let direction: Int
    let stops: [BusRouteStop]
    var id: Int { direction }

    var headingText: String { direction == 0 ? "去程" : "返程" }
}

struct LiveBus: Identifiable {
    let plate: String
    let stopSequence: Int
    let atStop: Bool
    var crowding: BusCrowding?
    var isLowFloor: Bool = false
    var hasLift: Bool = false
    var id: String { plate }
}

/// A bus's GPS position for the route map (from RealTimeByFrequency).
struct LiveBusPosition: Identifiable {
    let plate: String
    let direction: Int
    let coordinate: CLLocationCoordinate2D
    let azimuth: Double
    var crowding: BusCrowding?
    var id: String { plate }
}

/// A route plus the scope (region / InterCity) it belongs to.
struct ScopedRoute: Identifiable, Hashable {
    let scope: BusScope
    let route: BusRoute
    var id: String { route.routeUID }
}

struct BusService {
    static let shared = BusService()
    private let client = TDXClient.shared

    /// Exact route-name match. The `.../{RouteName}` path form does a *substring* match
    /// on TDX, so a short name like "1" pulls in "10", "100", "藍1"… — use `$filter`.
    private func nameFilter(_ routeName: String) -> [String: String] {
        let escaped = routeName.replacingOccurrences(of: "'", with: "''")
        return ["$filter": "RouteName/Zh_tw eq '\(escaped)'"]
    }

    // MARK: Route search (single scope)

    func searchRoutes(scope: BusScope, keyword: String) async throws -> [BusRoute] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        let routes: [BusRoute] = try await client.get(
            "v2/Bus/Route/\(scope.pathComponent)",
            query: [
                "$filter": "contains(RouteName/Zh_tw,'\(escaped)')",
                "$select": "RouteUID,RouteName,DepartureStopNameZh,DestinationStopNameZh",
                "$top": "25",
            ]
        )
        return routes
    }

    // MARK: Nationwide route search (fan-out across every scope)

    /// Searches 公路客運 + cities at once. `regionFilter` narrows to one scope.
    /// `expanded` = every county too (default: 公路客運 + 直轄市 + 基隆/新竹).
    /// `partial` is true when one or more scopes failed and were skipped.
    func searchAllRoutes(
        keyword: String, regionFilter: BusScope? = nil, expanded: Bool = false
    ) async -> (routes: [ScopedRoute], partial: Bool) {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else { return ([], false) }
        var scopes: [BusScope]
        if let regionFilter {
            scopes = [regionFilter]
        } else if expanded {
            scopes = BusScope.all
        } else {
            // Priority scopes + any scope whose catalog is already on-device (local filter
            // is free, so there's no reason to leave those out of a nationwide search).
            let built = await BusRouteCatalog.shared.builtScopeKeys()
            let extra = BusScope.all.filter { built.contains($0.storageKey) && !BusScope.priority.contains($0) }
            scopes = BusScope.priority + extra
        }

        var collected: [ScopedRoute] = []
        var partial = false

        // Fast path: scopes with an on-device catalog resolve instantly. The rest fall
        // through to the network fan-out, and every scope gets a background catalog build.
        var networkScopes: [BusScope] = []
        for scope in scopes {
            if let hits = await BusRouteCatalog.shared.search(scope, keyword: trimmed) {
                collected.append(contentsOf: hits.map { ScopedRoute(scope: scope, route: $0) })
            } else {
                networkScopes.append(scope)
            }
            await BusRouteCatalog.shared.ensureFresh(scope)
        }

        // Windowed fan-out: keep at most `maxActive` requests in flight so TDX doesn't rate-limit us.
        await withTaskGroup(of: (BusScope, [BusRoute]?).self) { group in
            var iterator = networkScopes.makeIterator()
            let maxActive = 3

            @discardableResult
            func launchNext() -> Bool {
                guard let scope = iterator.next() else { return false }
                group.addTask {
                    do { return (scope, try await BusService.shared.searchRoutes(scope: scope, keyword: trimmed)) }
                    catch { return (scope, nil) }
                }
                return true
            }

            for _ in 0..<maxActive { launchNext() }
            for await (scope, routes) in group {
                if let routes {
                    collected.append(contentsOf: routes.map { ScopedRoute(scope: scope, route: $0) })
                } else {
                    partial = true
                }
                launchNext()
            }
        }

        var seen = Set<String>()
        let deduped = collected.filter { seen.insert($0.route.routeUID).inserted }
        // Rank: exact match → prefix match → everything else, then natural order.
        let kw = trimmed.lowercased()
        func rank(_ name: String) -> Int {
            let n = name.lowercased()
            if n == kw { return 0 }
            if n.hasPrefix(kw) { return 1 }
            return 2
        }
        let sorted = deduped.sorted { a, b in
            let ra = rank(a.route.name), rb = rank(b.route.name)
            if ra != rb { return ra < rb }
            return a.route.name == b.route.name
                ? a.scope.displayName < b.scope.displayName
                : natCompare(a.route.name, b.route.name)
        }
        // A 1–2 char query like "1" or "88" matches hundreds of routes; keep the list usable.
        return (Array(sorted.prefix(80)), partial)
    }

    // MARK: Stops of route

    func directions(scope: BusScope, routeName: String) async throws -> [RouteDirection] {
        let raw: [BusStopOfRoute] = try await client.get(
            "v2/Bus/StopOfRoute/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        var longest: [Int: [BusRouteStop]] = [:]
        for entry in raw {
            let existing = longest[entry.direction]?.count ?? -1
            if entry.stops.count > existing { longest[entry.direction] = entry.stops }
        }
        return longest
            .sorted { $0.key < $1.key }
            .map { RouteDirection(direction: $0.key, stops: $0.value.sorted { $0.stopSequence < $1.stopSequence }) }
    }

    // MARK: Route info & schedule

    func routeInfo(scope: BusScope, routeName: String) async throws -> BusRouteInfo {
        let list: [BusRouteInfo] = try await client.get(
            "v2/Bus/Route/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        return list.first ?? BusRouteInfo(operators: [], routeMapImageUrl: nil, ticketPriceDescriptionZh: nil)
    }

    func schedule(scope: BusScope, routeName: String) async throws -> [BusScheduleEntry] {
        try await client.get("v2/Bus/Schedule/\(scope.pathComponent)", query: nameFilter(routeName))
    }

    /// All routes' next arrivals at one stop.
    func arrivals(city: BusCity, stopUID: String) async throws -> [StopArrival] {
        try await arrivals(city: city, stopUIDs: [stopUID])
    }

    /// Same as `arrivals(city:stopUID:)` but for several physical stop UIDs that were
    /// merged into one logical stop (e.g. "婦幼館" / "婦幼館站") — the results are the
    /// union of routes serving any of them.
    func arrivals(city: BusCity, stopUIDs: [String]) async throws -> [StopArrival] {
        try await arrivals(scope: .city(city), stopUIDs: stopUIDs)
    }

    /// Same as above but scope-general — routes like intercity coach 5900 (新竹縣政府↔高鐵新竹站)
    /// live under `.interCity`, not any city, so anything scoped to a single `BusCity` alone
    /// will never see them at a stop that only intercity coaches serve.
    func arrivals(scope: BusScope, stopUIDs: [String]) async throws -> [StopArrival] {
        guard !stopUIDs.isEmpty else { return [] }
        let filter = stopUIDs.map { "StopUID eq '\($0)'" }.joined(separator: " or ")
        let raw: [RawStopETA] = try await client.get(
            "v2/Bus/EstimatedTimeOfArrival/\(scope.pathComponent)",
            query: [
                "$filter": filter,
                "$select": "RouteName,Direction,EstimateTime,StopStatus",
                "$top": "160",
            ]
        )
        return raw
            .map { StopArrival(routeName: $0.routeName.display, direction: $0.direction,
                               estimateTime: $0.estimateTime, stopStatus: $0.stopStatus) }
            .sorted {
                $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : natCompare($0.routeName, $1.routeName)
            }
    }

    // MARK: Realtime

    func estimates(scope: BusScope, routeName: String) async throws -> [String: BusEstimate] {
        let list: [BusEstimate] = try await client.get(
            "v2/Bus/EstimatedTimeOfArrival/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        var map: [String: BusEstimate] = [:]   // key: "\(direction)-\(stopUID)"
        for e in list { map["\(e.direction)-\(e.stopUID)"] = e }
        return map
    }

    // MARK: Route geometry + live positions (for the map)

    /// Route shape per direction, as coordinate lists parsed from the WKT LINESTRING.
    func shape(scope: BusScope, routeName: String) async throws -> [Int: [CLLocationCoordinate2D]] {
        let entries: [BusShapeEntry] = try await client.get(
            "v2/Bus/Shape/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        var longest: [Int: [CLLocationCoordinate2D]] = [:]
        for e in entries {
            guard let dir = e.direction, let wkt = e.geometry else { continue }
            let coords = Self.parseLineString(wkt)
            if coords.count > (longest[dir]?.count ?? 0) { longest[dir] = coords }
        }
        return longest
    }

    /// Live bus GPS positions per direction (RealTimeByFrequency).
    func liveBusPositions(scope: BusScope, routeName: String) async throws -> [Int: [LiveBusPosition]] {
        let list: [BusRealTimeFreq] = try await client.get(
            "v2/Bus/RealTimeByFrequency/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        let active = list.filter {
            $0.plateNumb != "-1" && !$0.plateNumb.isEmpty
                && $0.busPosition?.positionLat != nil && $0.busPosition?.positionLon != nil
        }
        var crowdingByPlate: [String: BusCrowding] = [:]
        if scope.hasCrowding {
            let demo = await AppSettings.shared.crowdingDemoMode
            crowdingByPlate = await CrowdingProvider.shared.crowding(
                forPlates: active.map(\.plateNumb), demo: demo
            )
        }
        var byDir: [Int: [LiveBusPosition]] = [:]
        for b in active {
            guard let lat = b.busPosition?.positionLat, let lon = b.busPosition?.positionLon else { continue }
            byDir[b.direction, default: []].append(
                LiveBusPosition(
                    plate: b.plateNumb,
                    direction: b.direction,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    azimuth: b.azimuth ?? 0,
                    crowding: crowdingByPlate[normalizedPlate(b.plateNumb)]
                )
            )
        }
        return byDir
    }

    /// `LINESTRING (lon lat, lon lat, ...)` → coordinates.
    private static func parseLineString(_ wkt: String) -> [CLLocationCoordinate2D] {
        guard let open = wkt.firstIndex(of: "("), let close = wkt.lastIndex(of: ")") else { return [] }
        let inner = wkt[wkt.index(after: open)..<close]
        return inner.split(separator: ",").compactMap { pair in
            let n = pair.split(separator: " ").compactMap { Double($0) }
            guard n.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: n[1], longitude: n[0])
        }
    }

    func liveBuses(scope: BusScope, routeName: String) async throws -> [Int: [LiveBus]] {
        let nearStop: [BusRealTimeNearStop] = try await client.get(
            "v2/Bus/RealTimeNearStop/\(scope.pathComponent)", query: nameFilter(routeName)
        )
        let active = nearStop.filter { $0.plateNumb != "-1" && !$0.plateNumb.isEmpty }

        var crowdingByPlate: [String: BusCrowding] = [:]
        if scope.hasCrowding {
            let demo = await AppSettings.shared.crowdingDemoMode
            crowdingByPlate = await CrowdingProvider.shared.crowding(
                forPlates: active.map(\.plateNumb), demo: demo
            )
        }
        let vehicles = await VehicleProvider.shared.vehicles(scope: scope)

        var byDirection: [Int: [LiveBus]] = [:]
        for b in active {
            let v = vehicles[normalizedPlate(b.plateNumb)]
            let bus = LiveBus(
                plate: b.plateNumb,
                stopSequence: b.stopSequence,
                atStop: (b.a2EventType ?? 0) == 1,
                crowding: crowdingByPlate[normalizedPlate(b.plateNumb)],
                isLowFloor: v?.lowFloor ?? false,
                hasLift: v?.lift ?? false
            )
            byDirection[b.direction, default: []].append(bus)
        }
        return byDirection
    }
}

/// Natural-order compare so "3" < "12" < "307" < "672".
func natCompare(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
}
