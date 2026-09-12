import Foundation
import CoreLocation

/// A fixed traffic-camera location (speed enforcement, intersection violation, etc.) from
/// the backend's nationwide open-data cache — see transitgo-server/src/speedcampoller.mjs.
/// No TDX involved, so it's not subject to TDX's rate limit.
struct SpeedCam: Decodable, Identifiable {
    let lat: Double
    let lon: Double
    let kind: String        // "speed" | "intersection" | "pedestrian" | "violation"
    let address: String?
    let city: String?
    let direction: String?
    let speedLimit: Int?
    let note: String?
    let source: String
    var distance: Int?

    var id: String { "\(source)_\(lat)_\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// What to actually say out loud when approaching this camera.
    var announcement: String {
        switch kind {
        case "speed":
            if let limit = speedLimit { return "前方有測速照相，速限\(limit)公里" }
            return "前方有測速照相"
        case "intersection": return "前方有路口違規照相"
        case "pedestrian": return "前方有行人優先照相，請禮讓行人"
        default: return "前方有違規照相"
        }
    }
}

enum SpeedCamService {
    private struct Response: Decodable {
        let cams: [SpeedCam]
        let updatedAt: String?
    }

    /// `nil` means the backend isn't configured/reachable — callers should just skip the
    /// alert rather than treat it as "confirmed no cameras nearby".
    static func nearby(near coord: CLLocationCoordinate2D, radius: Int = 3000) async -> [SpeedCam]? {
        guard let base = BackendConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/speedcams/nearby"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        guard let url = comps?.url else { return nil }

        // Same cold-start-tolerant pattern as SharedBikeService: quick try, then one
        // longer-timeout retry instead of giving up outright.
        if let cams = try? await fetch(url, timeoutInterval: 6) { return cams }
        return try? await fetch(url, timeoutInterval: 20)
    }

    private static func fetch(_ url: URL, timeoutInterval: TimeInterval) async throws -> [SpeedCam] {
        let request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).cams
    }
}
