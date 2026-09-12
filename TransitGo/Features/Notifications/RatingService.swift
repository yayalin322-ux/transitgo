import Foundation

/// Average rating for one route/train, Google-Maps style (★4.3 · 12 則評分).
struct RouteRatingStats: Decodable {
    let count: Int
    let avg: Double?
}

/// Fire-and-forget upload of a trip rating to the self-hosted backend.
/// No-ops when `BackendHost` isn't configured.
enum RatingService {
    /// `nil` when the backend isn't configured, unreachable, or there's no rating yet.
    static func stats(kind: String, route: String, system: String? = nil) async -> RouteRatingStats? {
        guard let base = BackendConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/ratings/route"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "route", value: route)]
        if let system { items.append(URLQueryItem(name: "system", value: system)) }
        comps?.queryItems = items
        guard let url = comps?.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let stats = try? JSONDecoder().decode(RouteRatingStats.self, from: data),
              stats.count > 0 else { return nil }
        return stats
    }

    static func submit(stars: Int, kind: String, route: String, from: String, to: String, system: String) {
        guard let base = BackendConfig.baseURL else { return }
        let payload: [String: Any] = [
            "stars": stars,
            "kind": kind,
            "route": route,
            "from": from,
            "to": to,
            "system": system,
            "appVersion": BackendConfig.appVersion,
        ]
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/ratings"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
