import Foundation
import CoreLocation

/// Nearest bus stops from OUR backend (`GET /v1/bus/nearby`), which answers from its routing graph.
/// Stop positions are static, and asking TDX for them from every phone burns a tiny shared quota
/// (and needs the key inside the app), so the app asks the backend first and only falls back to
/// TDX when the backend cannot answer or has no bus data at this spot.
enum NearbyBusService {

    struct Response: Decodable {
        let ok: Bool
        /// false = the graph has no bus data near the point. That is "unknown", never "no stops".
        let covered: Bool
        let stops: [Stop]

        struct Stop: Decodable {
            let name: String
            let lat: Double
            let lon: Double
            let distanceMeters: Int
            let stops: [Ref]
        }
        struct Ref: Decodable {
            let scope: String        // "City/Taipei" | "InterCity"
            let stopUID: String
        }
    }

    /// Physical stops around `coord`, or nil when the backend could not answer or does not cover the
    /// area (caller falls back). `city` is the region's own bus city: refs under it become
    /// `stopUIDs`, InterCity refs become `interCityUIDs`. Refs under a *different* city (a stop on a
    /// city boundary) are not requested — this app resolves one bus city per region.
    static func stops(near coord: CLLocationCoordinate2D, radius: Int, limit: Int, city: BusCity) async -> [MergedStop]? {
        guard let base = BackendConfig.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("v1/bus/nearby"), resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps.url else { return nil }
        // Render's free tier sleeps when idle and needs 30–50 s to wake: a short first try skips a
        // sleeping backend quickly, one longer retry catches a backend that is just waking.
        let response: Response?
        if let r = await fetch(url, timeout: 6) { response = r } else { response = await fetch(url, timeout: 20) }
        guard let response, response.ok, response.covered else { return nil }
        return merged(response, city: city)
    }

    static func merged(_ response: Response, city: BusCity) -> [MergedStop] {
        response.stops.map { s in
            MergedStop(
                stopUIDs: s.stops.filter { $0.scope == "City/\(city.rawValue)" }.map(\.stopUID),
                displayName: s.name,
                coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                interCityUIDs: s.stops.filter { $0.scope == "InterCity" }.map(\.stopUID)
            )
        }
        // A stop whose only refs belong to another city has nothing this region can query.
        .filter { !($0.stopUIDs.isEmpty && $0.interCityUIDs.isEmpty) }
    }

    private static func fetch(_ url: URL, timeout: TimeInterval) async -> Response? {
        guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout)),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
