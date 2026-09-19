import Foundation
import CoreLocation

/// The ONE service every YouBike read goes through — the "nearby" lists and map, the availability
/// of specific stations, and the candidate stations route planning uses. All of it comes from our
/// backend (`/v1/bike/*`), which owns the shared snapshot the router itself reads, so the app can
/// never show a station as rentable while planning treats it as empty (or the reverse).
///
/// Realtime reads (`availability`, `routingCandidates`) share `RealtimeTransitService`'s cache and
/// in-flight de-duplication: the same stations asked twice within the TTL cost one request.
/// (`SharedBikeService` is now a thin, deprecated forwarder to this.)
enum BikeStationService {

    /// Client cache lifetime for realtime bike reads. The backend re-reads its snapshot every 15 s
    /// and the poller refreshes it every 2 min, so anything shorter than this could not be fresher.
    static let realtimeTTL: TimeInterval = 10

    // MARK: Wire types

    private struct NearbyResponse: Decodable {
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

    // MARK: nearby (map + lists)

    /// `city: nil` searches the backend's whole nationwide cache (every city the poller
    /// tracks), not just one — that's what lets the map keep showing stations as you pan
    /// across a county border. `nil` return means the backend isn't configured / unreachable
    /// / has no data yet.
    static func nearby(near coord: CLLocationCoordinate2D, radius: Int = 900, city: BikeCity?) async -> [BikeStationLive]? {
        guard let base = BackendConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/bike/nearby"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        if let city { items.append(URLQueryItem(name: "city", value: city.rawValue)) }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }

        // Render's free tier sleeps after ~15 min idle and takes 30-50s to wake up — a short first
        // attempt skips a sleeping backend quickly; callers that gave it a head start (see
        // Prewarm.wakeBackend()) get one retry at a longer timeout.
        if let stations = try? await fetchNearby(url, near: coord, timeoutInterval: 6) { return stations }
        return try? await fetchNearby(url, near: coord, timeoutInterval: 20)
    }

    private static func fetchNearby(_ url: URL, near coord: CLLocationCoordinate2D, timeoutInterval: TimeInterval) async throws -> [BikeStationLive] {
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeoutInterval))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(NearbyResponse.self, from: data)
        guard !decoded.stations.isEmpty else { throw URLError(.zeroByteResource) }
        return decoded.stations.map { live(from: $0, updatedAt: decoded.updatedAt, near: coord) }
    }

    /// Nationwide name search — every city the backend's poller tracks, not just what's on screen.
    static func search(keyword: String, limit: Int = 20) async -> [BikeStationLive]? {
        guard let base = BackendConfig.baseURL, !keyword.isEmpty else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/bike/search"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "q", value: keyword), URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps?.url,
              let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(NearbyResponse.self, from: data) else { return nil }
        return decoded.stations.map { live(from: $0, updatedAt: nil, near: nil) }
    }

    private static func live(from r: Row, updatedAt: String?, near coord: CLLocationCoordinate2D?) -> BikeStationLive {
        let station = BikeStation(
            stationUID: r.uid,
            stationName: LocalizedName(zhTw: r.name, en: nil),
            stationPosition: GeoPoint(lat: r.lat, lon: r.lon),
            stationAddress: LocalizedName(zhTw: r.address ?? "", en: nil),
            bikesCapacity: r.capacity
        )
        let avail = BikeAvailability(
            stationUID: r.uid, serviceStatus: r.status,
            availableRentBikes: r.rent, availableReturnBikes: r.ret,
            availableRentBikesDetail: BikeDetail(generalBikes: r.general, electricBikes: r.electric),
            srcUpdateTime: updatedAt
        )
        let resolvedCity = r.city.flatMap(BikeCity.init(rawValue:))
            ?? coord.flatMap { BikeCity.nearest(to: $0, count: 1).first } ?? .taipei
        var live = BikeStationLive(station: station, availability: avail, city: resolvedCity)
        live.distance = Double(r.distance ?? 0)
        return live
    }

    // MARK: availability (realtime)

    struct AvailabilityResult {
        /// False when the backend's snapshot could not be read — every station is then unknown.
        let isAvailable: Bool
        let stations: [String: BikeStationRealtime]
    }

    /// Realtime state of specific stations, by the ids route planning returns ("BIKE_Taipei:500101001").
    /// A station missing from `stations` is UNKNOWN (never assumed available or empty).
    static func availability(stationIds: [String]) async -> AvailabilityResult {
        let ids = Array(Set(stationIds)).sorted().prefix(50)
        guard !ids.isEmpty, let base = BackendConfig.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("v1/bike/availability"), resolvingAgainstBaseURL: false)
        else { return AvailabilityResult(isAvailable: false, stations: [:]) }
        comps.queryItems = [URLQueryItem(name: "stations", value: ids.joined(separator: ","))]
        guard let url = comps.url else { return AvailabilityResult(isAvailable: false, stations: [:]) }
        let key = "bikeAvail|" + ids.joined(separator: ",")
        return await RealtimeTransitService.shared.coalesced(key: key, ttl: realtimeTTL, isFailure: { !$0.isAvailable }) {
            struct Wire: Decodable { let available: Bool; let stations: [BikeStationRealtime?] }
            guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.available
            else { return AvailabilityResult(isAvailable: false, stations: [:]) }
            return AvailabilityResult(isAvailable: true, stations: Dictionary(uniqueKeysWithValues: wire.stations.compactMap { $0 }.map { ($0.stationId, $0) }))
        }
    }

    // MARK: routing candidates

    enum Role: String { case rent, `return` }

    struct Candidate: Decodable, Identifiable {
        let stationId: String
        let name: String
        let lat: Double
        let lon: Double
        let distanceMeters: Int
        /// nil = the realtime snapshot has nothing for this station (unknown, not "empty").
        let availability: BikeStationRealtime?
        let availabilityKnown: Bool
        var id: String { stationId }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    struct Candidates {
        let role: Role
        let realtimeAvailable: Bool
        let stations: [Candidate]
    }

    /// The nearest stations that can be USED right now for `role` (a bike to take / a free dock to
    /// return to), by the same graph index and availability snapshot the router uses. Stations whose
    /// state can't be confirmed come back flagged (`availabilityKnown == false`), not dropped.
    /// nil = the backend couldn't answer (offline / routing graph still loading).
    static func routingCandidates(near coord: CLLocationCoordinate2D, role: Role, radius: Int = 800) async -> Candidates? {
        guard let base = BackendConfig.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("v1/bike/candidates"), resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", coord.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", coord.longitude)),
            URLQueryItem(name: "role", value: role.rawValue),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        guard let url = comps.url else { return nil }
        let key = "bikeCand|\(role.rawValue)|\(radius)|" + (comps.queryItems?.prefix(2).compactMap(\.value).joined(separator: ",") ?? "")
        let result = await RealtimeTransitService.shared.coalesced(key: key, ttl: realtimeTTL, isFailure: { $0 == nil }) { () -> Candidates? in
            struct Wire: Decodable { let realtimeAvailable: Bool; let stations: [Candidate] }
            guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
            return Candidates(role: role, realtimeAvailable: wire.realtimeAvailable, stations: wire.stations)
        }
        return result
    }
}
