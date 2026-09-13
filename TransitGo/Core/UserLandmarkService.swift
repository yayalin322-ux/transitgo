import Foundation
import CoreLocation

/// A real, admin-approved user-submitted landmark from our own backend — see
/// transitgo-server's /v1/landmarks. Only approved ones are ever returned by the public
/// GET endpoint, so anything the app shows here has already passed moderation.
struct UserLandmark: Decodable, Identifiable {
    let id: Int
    let name: String
    let description: String
    let lat: Double
    let lon: Double
    let photo: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// User-submitted landmarks (real content, e.g. a small shop/spot Apple's POI index
/// doesn't have) — held for admin approval before anyone else sees them, same principle
/// as this app's other user-generated content (place reviews).
enum UserLandmarkService {
    static func nearby(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double = 1000) async -> [UserLandmark] {
        guard let base = BackendConfig.baseURL else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("v1/landmarks"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "radius", value: String(radiusMeters)),
        ]
        struct Response: Decodable { let landmarks: [UserLandmark] }
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.landmarks
    }

    static func submit(name: String, description: String, coordinate: CLLocationCoordinate2D, photo: String?) {
        guard let base = BackendConfig.baseURL else { return }
        var payload: [String: Any] = [
            "name": name,
            "description": description,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "appVersion": BackendConfig.appVersion,
        ]
        if let photo { payload["photo"] = photo }
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/landmarks"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
