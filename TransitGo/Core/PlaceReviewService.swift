import Foundation
import CoreLocation

struct PlaceReview: Decodable, Identifiable {
    let id: Int
    let stars: Int
    let comment: String
    /// A `data:image/jpeg;base64,...` URI, if the reviewer attached a photo.
    let photo: String?
    let createdAt: String
}

struct PlaceReviewStats: Decodable {
    let count: Int
    let avg: Double?
}

/// Real user-submitted place reviews stored on our own backend — see the "免費的
/// apple的" conversation: Apple's MapKit has no review data at all, and a real reviews
/// API (Google Places) needs a billed account, so this is entirely our own data instead.
enum PlaceReviewService {
    /// Stable-enough key since MapKit gives third parties no real place ID — name plus
    /// coordinate rounded to ~11m precision, so the same real-world place searched twice
    /// keys the same even with tiny GPS jitter, but distinct places with the same name
    /// (there can be more than one "全家" nearby) don't collide.
    static func key(name: String, coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10000).rounded() / 10000
        let lon = (coordinate.longitude * 10000).rounded() / 10000
        return "\(name)_\(lat)_\(lon)"
    }

    private struct ListResponse: Decodable {
        let stats: PlaceReviewStats
        let reviews: [PlaceReview]
    }

    static func fetch(name: String, coordinate: CLLocationCoordinate2D) async -> (stats: PlaceReviewStats, reviews: [PlaceReview])? {
        guard let base = BackendConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("v1/places/reviews"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "placeKey", value: key(name: name, coordinate: coordinate))]
        guard let url = comps?.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else { return nil }
        return (decoded.stats, decoded.reviews)
    }

    enum SubmitResult { case ok, invalidCode, failed }

    /// A verified Email is required now — see the server's /v1/places/reviews for why
    /// (anonymous drive-by comments were the whole problem). Get a code first with
    /// `EmailVerificationService.requestCode(email:)`.
    static func submit(
        name: String, coordinate: CLLocationCoordinate2D, stars: Int, comment: String,
        email: String, code: String, photo: String? = nil
    ) async -> SubmitResult {
        guard let base = BackendConfig.baseURL else { return .failed }
        var payload: [String: Any] = [
            "placeKey": key(name: name, coordinate: coordinate),
            "placeName": name,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "stars": stars,
            "comment": comment,
            "appVersion": BackendConfig.appVersion,
            "device": BackendConfig.deviceID,
            "email": email,
            "code": code,
        ]
        if let photo { payload["photo"] = photo }
        var req = URLRequest(url: base.appendingPathComponent("v1/places/reviews"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 200 { return .ok }
        return status == 400 ? .invalidCode : .failed
    }

    /// Self-service delete: only the device that posted it can remove it — no separate token,
    /// the app already sends its own device id on every review it posts.
    @discardableResult
    static func deleteMine(id: Int) async -> Bool {
        guard let base = BackendConfig.baseURL else { return false }
        var req = URLRequest(url: base.appendingPathComponent("v1/places/reviews/\(id)"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device": BackendConfig.deviceID])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// This device's own reviews (any place) — lets the app show "your review" with a delete
    /// button, without the public /v1/places/reviews listing ever revealing whose device posted
    /// what (same principle as UserLandmarkService.mine()).
    struct MyPlaceReview: Decodable, Identifiable {
        let id: Int
        let placeKey: String
        let placeName: String
        let stars: Int
        let comment: String
        let photo: String?
        let createdAt: String
    }
    static func mine() async -> [MyPlaceReview] {
        guard let base = BackendConfig.baseURL else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("v1/places/reviews/mine"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "device", value: BackendConfig.deviceID)]
        struct Response: Decodable { let reviews: [MyPlaceReview] }
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.reviews
    }

    /// Cross-device: on a different phone, there's no device id to match, only a freshly
    /// verified Email — get a code first with `EmailVerificationService.requestCode(email:)`.
    static func mine(email: String, code: String) async -> [MyPlaceReview] {
        guard let base = BackendConfig.baseURL else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("v1/places/reviews/mine"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "code": code])
        struct Response: Decodable { let reviews: [MyPlaceReview] }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.reviews
    }

    /// Self-service delete via a freshly-verified Email (the cross-device case) — same as
    /// `deleteMine(id:)` but without a device id to prove ownership.
    @discardableResult
    static func deleteMine(id: Int, email: String, code: String) async -> Bool {
        guard let base = BackendConfig.baseURL else { return false }
        var req = URLRequest(url: base.appendingPathComponent("v1/places/reviews/\(id)"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "code": code])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Flags a review as inappropriate — visible to admins as a categorized report
    /// (not just a bare count), so they can triage quickly. Not an automatic takedown
    /// (see transitgo-server's /v1/admin/place-reviews).
    static func report(id: Int, reason: ReportReason) {
        guard let base = BackendConfig.baseURL else { return }
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/places/reviews/\(id)/report"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason.rawValue])
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}

/// Matches transitgo-server's REPORT_REASONS exactly.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam, offensive, sexual, harassment, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: return "廣告／垃圾訊息"
        case .offensive: return "不當言論"
        case .sexual: return "色情內容"
        case .harassment: return "騷擾／人身攻擊"
        case .other: return "其他"
        }
    }
}
