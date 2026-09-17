import Foundation

/// What the backend's multimodal routing engine actually has real data for right now —
/// GET /v1/routing/coverage, computed server-side from the live graph itself (see
/// routing/api.mjs's graphCoverage()), not a sentence someone has to remember to update
/// every time a new city gets ingested. That's exactly what went stale before: the
/// in-app footer said "測試中，目前僅新竹市／縣有真實資料" long after Taoyuan, Taipei,
/// New Taipei, TRA and THSR were all ingested.
struct RoutingCoverage: Decodable {
    let bus: [String]
    let rail: [String]
    let nodeCount: Int
    let edgeCount: Int
    let builtAt: String?

    /// "新竹市公車、新竹縣公車、台鐵、高鐵" — nil only when there's genuinely nothing yet.
    var summaryText: String? {
        let parts = bus + rail
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "、")
    }
}

enum RoutingCoverageService {
    /// Cached for the process lifetime — coverage only changes after an ingest+rebuild,
    /// not something worth re-fetching on every screen open.
    private static var cached: RoutingCoverage?

    static func current() async -> RoutingCoverage? {
        if let cached { return cached }
        guard let base = BackendConfig.baseURL else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("v1/routing/coverage"), timeoutInterval: 8)
        req.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let coverage = try? JSONDecoder().decode(RoutingCoverage.self, from: data) else { return nil }
        cached = coverage
        return coverage
    }
}
