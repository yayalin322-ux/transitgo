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

    static func create(route: MultimodalRoute, title: String) async -> Result<URL, Failure> {
        guard isShareable(route) else { return .failure(.nothingToFollow) }
        guard let body = try? requestBody(route: route, title: title) else { return .failure(.backendUnavailable) }
        return await post(body)
    }

    static func post(_ body: Data) async -> Result<URL, Failure> {
        guard let base = BackendConfig.baseURL else { return .failure(.backendUnavailable) }
        // The free-tier backend sleeps when idle and needs up to a minute to wake: a short try, then a long one.
        for timeout in [8.0, 45.0] {
            var req = URLRequest(url: base.appendingPathComponent("v1/shares"), timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok,
               let s = reply.url, let url = URL(string: s) {
                return .success(url)
            }
        }
        return .failure(.backendUnavailable)
    }
}

/// Items for the system share sheet, presentable with `.sheet(item:)`.
struct ShareSheetItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
