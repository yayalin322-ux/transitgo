import Foundation
import SwiftUI
import UIKit

/// Creates a shareable trip link on our backend. What is sent is only what is needed to look the public
/// vehicles up (mode, route, stop ids and names, boarded trip, planned times). NEVER coordinates, the device
/// id or the phone's own location — whoever opens the link sees the planned services and their status,
/// not where the sharer is.
enum ShareTripService {
    struct SegmentBody: Encodable, Equatable {
        let mode: String
        let routeId: String?
        let routeShortName: String?
        let scopePath: String?
        let line: String?
        let towards: String?
        let from: String?
        let to: String?
        let tripId: String?
        let fromName: String?
        let toName: String?
        let departureTime: String
        let arrivalTime: String

        init(mode: String, routeId: String?, line: String?, from: String?, to: String?, tripId: String?,
             fromName: String?, toName: String?, departureTime: String, arrivalTime: String) {
            self.mode = mode; self.routeId = routeId; routeShortName = nil; scopePath = nil
            self.line = line; towards = nil; self.from = from; self.to = to; self.tripId = tripId
            self.fromName = fromName; self.toName = toName
            self.departureTime = departureTime; self.arrivalTime = arrivalTime
        }

        init(_ s: MultimodalSegment) {
            mode = s.mode; routeId = s.routeId; routeShortName = s.routeShortName; scopePath = s.scopePath
            line = s.line; towards = s.towards; from = s.from; to = s.to; tripId = s.tripId
            fromName = s.fromName; toName = s.toName; departureTime = s.departureTime; arrivalTime = s.arrivalTime
        }
    }

    struct Body: Encodable { let title: String; let ttlHours: Int; let segments: [SegmentBody] }
    private struct Reply: Decodable { let ok: Bool; let url: String? }

    enum Failure: Error, Equatable {
        /// A walk-only trip has no vehicle to follow.
        case nothingToFollow
        case backendUnavailable
    }

    /// True when at least one leg is a vehicle (bus, metro, train, HSR).
    static func isShareable(_ route: MultimodalRoute) -> Bool {
        route.segments.contains { $0.mode != "WALK" && $0.mode != "BIKE" }
    }

    static func requestBody(route: MultimodalRoute, title: String, ttlHours: Int = 6) throws -> Data {
        try JSONEncoder().encode(Body(title: title, ttlHours: ttlHours, segments: route.segments.map(SegmentBody.init)))
    }

    /// A link that exists the moment the button is pressed. The token is made HERE (128 random bits — the same shape the server
    /// accepts) so the share sheet can open immediately; `body` is uploaded in the background with `ShareUploader`.
    struct Prepared: Equatable {
        let token: String
        let url: URL
        let body: Data
    }

    static func prepare(route: MultimodalRoute, title: String) -> Result<Prepared, Failure> {
        guard isShareable(route) else { return .failure(.nothingToFollow) }
        guard let body = try? requestBody(route: route, title: title) else { return .failure(.nothingToFollow) }
        return prepare(body: body)
    }

    static func prepare(body: Data) -> Result<Prepared, Failure> {
        let token = ShareLink.makeToken()
        guard let url = ShareLink.url(token: token) else { return .failure(.backendUnavailable) }
        return .success(Prepared(token: token, url: url, body: body))
    }
}

/// Link addresses. Pure, so the token shape is tested against the server's rule.
enum ShareLink {
    /// 22 URL-safe characters (`^[A-Za-z0-9_-]{22}$` on the server) from the system's secure random source.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }   // never happens; still never a fixed token
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func url(token: String, base: URL? = BackendConfig.shareBaseURL) -> URL? {
        base?.appendingPathComponent("s").appendingPathComponent(token)
    }

    static func isValid(_ token: String) -> Bool {
        token.count == 22 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Uploads a prepared link's content in the background. The backend can be asleep (free hosting wakes in up to a minute) or
/// busy, so a failed attempt is retried on a schedule instead of being reported at once; a request the server will never
/// accept (400) is not retried. The PUT is idempotent on the server, so a retry after a lost reply is harmless.
enum ShareUploader {
    enum Outcome: Equatable { case uploaded, failed }

    /// Seconds to wait before each attempt — about 90 s in all, longer than a cold start.
    static let schedule: [TimeInterval] = [0, 2, 4, 8, 15, 25, 35]

    /// Performs one PUT and returns its HTTP status (nil = network error/timeout). Injected so tests need no network.
    typealias Transport = (URLRequest) async -> Int?

    static func upload(_ prepared: ShareTripService.Prepared, base: URL? = BackendConfig.baseURL,
                       transport: Transport = defaultTransport, sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async -> Outcome {
        guard let base else { return .failed }
        for (i, wait) in schedule.enumerated() {
            if wait > 0 { await sleep(wait) }
            var req = URLRequest(url: base.appendingPathComponent("v1/shares/\(prepared.token)"), timeoutInterval: i == 0 ? 10 : 30)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = prepared.body
            switch await transport(req) {
            case 200?: return .uploaded
            case let code? where (400...499).contains(code) && code != 429 && code != 408: return .failed   // the server refused it for good
            default: continue                                                                             // 429, 5xx, timeout, offline
            }
        }
        return .failed
    }

    static let defaultTransport: Transport = { req in
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}
