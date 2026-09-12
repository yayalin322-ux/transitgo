import Foundation
import CoreLocation

/// Reads the self-hosted backend's shared YouBike snapshot (refreshed ~1 min
/// server-side by all users). App-only — depends on `BackendConfig`.
enum SharedBikeService {

    private struct Response: Decodable {
        let stations: [Row]
        let updatedAt: String?
    }
    private struct Row: Decodable {
        let uid: String
        let name: String
        let city: String?
        let lat: Double
        let lon: Double
        let address: String?
        let capacity: Int?
        let rent: Int?
        let ret: Int?
        let general: Int?
        let electric: Int?
        let status: Int?
        let distance: Int?
    }

    /// `city: nil` searches the backend's whole nationwide cache (every city the poller
    /// tracks), not just one — that's what lets the map keep showing stations as you pan
    /// across a county border. `nil` return means the backend isn't configured / unreachable
    /// / has no data yet.
    static func nearby(near coord: CLLocationCoordinate2D, radius: Int = 900, city: BikeCity?) async -> [BikeStationLive]? {
        guard let base = BackendConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/bike/nearby"),
                                  resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        if let city { items.append(URLQueryItem(name: "city", value: city.rawValue)) }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }

        // Render's free tier sleeps after ~15 min idle and takes 30-50s to wake up — a
        // default 60s URLSession timeout would make every caller of this function *wait*
        // that long before falling back to direct TDX. A short-ish timeout here means a
        // sleeping backend gets skipped reasonably quickly instead of stalling the UI, but
        // callers that already gave the backend a head start (see Prewarm.wakeBackend())
        // get one retry at a longer timeout instead of immediately giving up and falling
        // through to the (easily rate-limited) direct-TDX path.
        if let stations = try? await fetch(url, near: coord, timeoutInterval: 6) { return stations }
        return try? await fetch(url, near: coord, timeoutInterval: 20)
    }

    private static func fetch(_ url: URL, near coord: CLLocationCoordinate2D, timeoutInterval: TimeInterval) async throws -> [BikeStationLive] {
        let request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.stations.isEmpty else { throw URLError(.zeroByteResource) }

        return decoded.stations.map { r -> BikeStationLive in
            let station = BikeStation(
                stationUID: r.uid,
                stationName: LocalizedName(zhTw: r.name, en: nil),
                stationPosition: GeoPoint(lat: r.lat, lon: r.lon),
                stationAddress: LocalizedName(zhTw: r.address ?? "", en: nil),
                bikesCapacity: r.capacity
            )
            let detail = BikeDetail(generalBikes: r.general, electricBikes: r.electric)
            let avail = BikeAvailability(
                stationUID: r.uid,
                serviceStatus: r.status,
                availableRentBikes: r.rent,
                availableReturnBikes: r.ret,
                availableRentBikesDetail: detail,
                srcUpdateTime: decoded.updatedAt
            )
            let resolvedCity = r.city.flatMap(BikeCity.init(rawValue:))
                ?? BikeCity.nearest(to: coord, count: 1).first ?? .taipei
            var live = BikeStationLive(station: station, availability: avail, city: resolvedCity)
            live.distance = Double(r.distance ?? 0)
            return live
        }
    }

    /// Nationwide name search — every city the backend's poller tracks, not just what's
    /// on screen right now.
    static func search(keyword: String, limit: Int = 20) async -> [BikeStationLive]? {
        guard let base = BackendConfig.baseURL, !keyword.isEmpty else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/bike/search"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps?.url else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 6)   // see nearby(): don't stall on a sleeping backend
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        return decoded.stations.map { r -> BikeStationLive in
            let station = BikeStation(
                stationUID: r.uid,
                stationName: LocalizedName(zhTw: r.name, en: nil),
                stationPosition: GeoPoint(lat: r.lat, lon: r.lon),
                stationAddress: LocalizedName(zhTw: r.address ?? "", en: nil),
                bikesCapacity: r.capacity
            )
            let detail = BikeDetail(generalBikes: r.general, electricBikes: r.electric)
            let avail = BikeAvailability(
                stationUID: r.uid, serviceStatus: r.status,
                availableRentBikes: r.rent, availableReturnBikes: r.ret,
                availableRentBikesDetail: detail, srcUpdateTime: nil
            )
            let resolvedCity = r.city.flatMap(BikeCity.init(rawValue:)) ?? .taipei
            return BikeStationLive(station: station, availability: avail, city: resolvedCity)
        }
    }
}
