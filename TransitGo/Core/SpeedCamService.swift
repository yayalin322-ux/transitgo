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
        case "intersection":
            // The county's 取締項目 says what this junction actually enforces (紅燈、行人、迴轉…).
            if let items = EnforcementWording.spoken(note), !items.isEmpty { return "前方路口科技執法，取締\(items)" }
            return "前方有路口違規照相"
        case "pedestrian": return "前方有行人優先照相，請禮讓行人"
        default:
            if let items = EnforcementWording.spoken(note), !items.isEmpty { return "前方有違規照相，取締\(items)" }
            return "前方有違規照相"
        }
    }
}

/// Turns the official 取締項目 text ("闖紅燈、未依標誌標線號誌行駛、機車未依規定兩段式左轉") into a short spoken
/// list. Speed enforcement is dropped (a speed camera already announces its limit) and at most three items are
/// read so the call-out fits before the camera.
enum EnforcementWording {
    private static let table: [(match: String, say: String)] = [
        ("闖紅燈", "闖紅燈"),
        ("不禮讓行人", "不停讓行人"), ("未停讓行人", "不停讓行人"), ("不停讓行人", "不停讓行人"),
        ("違規迴轉", "違規迴轉"),
        ("兩段式左轉", "機車兩段式左轉"),
        ("跨越雙白線", "跨越雙白線"),
        ("未保持路口淨空", "路口未淨空"),
        ("未依標誌標線號誌", "不依號誌標線行駛"), ("不遵守道路交通標誌", "不依號誌標線行駛"),
        ("機車不在規定車道", "機車不在規定車道"),
        ("違規停車", "違規停車"), ("臨時停車", "違規停車"), ("違規上客", "違規上客"), ("違規攬客", "違規攬客"),
    ]

    static func spoken(_ note: String?, limit: Int = 3) -> String? {
        guard let note, !note.isEmpty else { return nil }
        var out: [String] = []
        for part in note.components(separatedBy: CharacterSet(charactersIn: "、，,；;")) {
            // The county writes "違規（臨時）停車" — drop the brackets so the wording still matches.
            let t = part.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: "")
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            guard let hit = table.first(where: { t.contains($0.match) }) else { continue }
            if !out.contains(hit.say) { out.append(hit.say) }
            if out.count == limit { break }
        }
        return out.isEmpty ? nil : out.joined(separator: "、")
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
