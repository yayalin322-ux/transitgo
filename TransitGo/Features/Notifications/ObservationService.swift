import Foundation

/// Crowd-sourced board / alight events, sent when the user taps the Live Activity
/// buttons. Also kept in-memory so THIS session's tracker can keep going if TDX
/// stops reporting the bus mid-trip. Fire-and-forget; no-ops without `BackendHost`.
@MainActor
final class ObservationService {
    static let shared = ObservationService()

    struct Local { var stopSequence: Int; var at: Date }
    /// plate → last stop we know the bus was at (from a user tap this session).
    private(set) var local: [String: Local] = [:]

    func report(route: String, plate: String?, stopUID: String, stopName: String,
                stopSequence: Int, kind: String, system: String) {
        if let plate { local[plate] = Local(stopSequence: stopSequence, at: Date()) }

        guard let base = BackendConfig.baseURL else { return }
        var payload: [String: Any] = [
            "route": route, "stopUID": stopUID, "stopName": stopName,
            "kind": kind, "system": system,
        ]
        if let plate { payload["plate"] = plate }
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/observations"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Best guess of a plate's current stop sequence when TDX has gone quiet:
    /// last reported stop, advanced ~1 stop per 90 s.
    func estimatedStopSequence(plate: String) -> Int? {
        guard let l = local[plate] else { return nil }
        let advanced = Int(Date().timeIntervalSince(l.at) / 90)
        return l.stopSequence + advanced
    }
}
