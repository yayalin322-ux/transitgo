import Foundation
import CoreLocation

/// One real per-stop hop from the backend's own routing engine — kept for detail/debug;
/// the UI itself should prefer `MultimodalRoute.segments` (one per real boarding, not
/// one per stop-to-stop edge).
struct MultimodalLeg: Decodable, Identifiable {
    let mode: String
    let routeId: String?
    let from: String
    let to: String
    let departureTime: String
    let arrivalTime: String
    let durationSeconds: Int
    let isEstimated: Bool
    /// Real distance for a WALK leg (nil for a ride — a bus/rail leg's real length isn't
    /// meaningful the way a walk's is here). Backend sums these into
    /// `MultimodalRoute.walkingDistanceMeters`; kept per-leg too for a detail view.
    let distanceMeters: Double?
    var id: String { from + to + departureTime }
}

/// One real boarding — WALK, or a continuous ride on one BUS/TRA/METRO route from the
/// stop you got on to the stop you get off, with real stop names from the backend's
/// ingested data (not fabricated). This is what the UI should render, one row each.
struct MultimodalSegment: Decodable, Identifiable {
    let mode: String
    let routeId: String?
    /// The route's real TDX display name (e.g. "20", "5900") — what TDX's live-position
    /// endpoints filter on, NOT the same as `routeId` (our internal id, e.g. "HSZ0020").
    /// Nil if the backend couldn't resolve it (older deploy, or db wasn't passed).
    let routeShortName: String?
    /// Real TDX scope path this route was ingested from (e.g. "City/Hsinchu",
    /// "InterCity") — needed to call the right live-position endpoint.
    let scopePath: String?
    let fromName: String?
    let toName: String?
    let fromLat: Double?
    let fromLng: Double?
    let toLat: Double?
    let toLng: Double?
    let departureTime: String
    let arrivalTime: String
    let durationSeconds: Int
    let stopsPassed: Int
    let isEstimated: Bool
    var id: String { (fromName ?? "") + (toName ?? "") + departureTime }

    var fromCoordinate: CLLocationCoordinate2D? {
        guard let fromLat, let fromLng else { return nil }
        return CLLocationCoordinate2D(latitude: fromLat, longitude: fromLng)
    }

    var toCoordinate: CLLocationCoordinate2D? {
        guard let toLat, let toLng else { return nil }
        return CLLocationCoordinate2D(latitude: toLat, longitude: toLng)
    }

    var modeIcon: String {
        switch mode {
        case "WALK": return "figure.walk"
        case "BUS": return "bus.fill"
        case "TRA": return "tram.fill"
        case "METRO": return "tram.fill.tunnel"
        default: return "arrow.forward"
        }
    }

    var modeLabel: String {
        switch mode {
        case "WALK": return "走路"
        case "BUS": return "公車" + (routeShortName.map { " \($0)" } ?? routeId.map { " \($0)" } ?? "")
        case "TRA": return "台鐵"
        case "METRO": return "捷運"
        default: return mode
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_Hant_TW")
        return f
    }()

    private static func clockText(_ iso: String) -> String? {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return nil }
        return clockFormatter.string(from: d)
    }

    var departureClock: String? { Self.clockText(departureTime) }
    var arrivalClock: String? { Self.clockText(arrivalTime) }
}

/// One real ranked itinerary — engine's own label (最快/最均衡/少轉乘/少走路) describing
/// which real metric it wins on.
struct MultimodalRoute: Decodable, Identifiable {
    let routeId: String
    let label: String
    let durationSeconds: Int
    let departureTime: String
    let arrivalTime: String
    let walkingSeconds: Int
    let waitingSeconds: Int
    let transitSeconds: Int
    let transfers: Int
    /// nil means "we don't have real fare data for this trip" — the backend never sends
    /// 0 to mean "unknown" (see transitgo-server's astar.mjs: a route's fare is only a
    /// real number when every leg's price is actually known, otherwise explicitly null).
    /// Must stay Optional here or decoding this whole response throws the moment any
    /// route has an unknown fare, which is every route today (no fare source is
    /// ingested yet) — silently breaking route results app-wide, not just hiding a price.
    let fare: Int?
    /// Real distance, summed from every WALK leg's own measured distance — 0 (not nil)
    /// when the trip genuinely has no walking, since that's a known, real answer.
    let walkingDistanceMeters: Double?
    let legs: [MultimodalLeg]
    let segments: [MultimodalSegment]
    var id: String { routeId }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_Hant_TW")
        return f
    }()

    /// "9:15 出發，預計 9:44 抵達" — nil if either timestamp fails to parse.
    var summaryText: String? {
        guard let dep = ISO8601DateFormatter().date(from: departureTime),
              let arr = ISO8601DateFormatter().date(from: arrivalTime) else { return nil }
        return "\(Self.clockFormatter.string(from: dep)) 出發，預計 \(Self.clockFormatter.string(from: arr)) 抵達"
    }

    /// "約 NT$165" when real, "票價暫無資料" when not — never "NT$0", which would read as
    /// a real (and wrong) claim that the trip is free.
    var fareText: String {
        guard let fare else { return "票價暫無資料" }
        return "約 NT$\(fare)"
    }

    /// "步行 680 m" / "步行 1.2 km" — nil when the backend didn't send a real distance
    /// (an older deploy) so callers can omit the row entirely rather than show "步行 0 m".
    var walkingDistanceText: String? {
        guard let m = walkingDistanceMeters else { return nil }
        return m < 1000 ? "步行 \(Int(m.rounded())) m" : String(format: "步行 %.1f km", m / 1000)
    }
}

private struct MultimodalRouteResponse: Decodable {
    let requestId: String?
    let routes: [MultimodalRoute]?
    let error: MultimodalRouteError?
}

private struct MultimodalRouteError: Decodable {
    let code: String
    let message: String
}

/// What actually happened on the last call — surfaced in the UI (while this feature is
/// new) so "nothing showed up" can be diagnosed from the phone alone, without needing a
/// dev console attached: was it never even reachable, did the server reject the request
/// shape, or did it genuinely have no real data for this area yet.
enum MultimodalRoutingOutcome {
    case success([MultimodalRoute])
    case serverError(code: String, message: String)
    case unreachable(String)
}

/// Real multimodal routing from the backend's own routing engine (Virtual Origin/
/// Destination + Time-Dependent A* over real ingested TDX data — see transitgo-server's
/// src/routing/). Coverage is currently real but partial (only areas that have been
/// ingested have any edges at all), so NO_ROUTE / NO_ORIGIN_NEARBY here does NOT mean
/// "no route exists" — it means this engine doesn't have real data for that area yet.
/// Callers should treat a nil/empty result as "try the existing bus/metro/rail planners
/// instead", never as a confirmed negative.
enum MultimodalRoutingService {
    static func plan(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, departureTime: Date = Date()) async -> MultimodalRoutingOutcome {
        guard let base = BackendConfig.baseURL else { return .unreachable("後端未設定") }
        let payload: [String: Any] = [
            "origin": ["lat": origin.latitude, "lng": origin.longitude],
            "destination": ["lat": destination.latitude, "lng": destination.longitude],
            "departureTime": ISO8601DateFormatter().string(from: departureTime),
        ]
        var req = URLRequest(url: base.appendingPathComponent("api/v1/routes"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let decoded = try? JSONDecoder().decode(MultimodalRouteResponse.self, from: data) else {
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let raw = String(data: data.prefix(200), encoding: .utf8) ?? ""
            return .unreachable("解析失敗 http=\(http) \(raw)")
        }
        if let routes = decoded.routes {
            return .success(routes)
        }
        if let err = decoded.error {
            return .serverError(code: err.code, message: err.message)
        }
        return .unreachable("未知回應格式")
    }
}
