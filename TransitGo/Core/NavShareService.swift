import Foundation
import CoreLocation

/// Sharing an in-app driving/scooter/walking navigation trip. Same privacy rule as
/// ShareTripService: NEVER a coordinate, device id or the phone's own live position — only the
/// destination name and, while navigating, coarse "how much further / how long" progress (the
/// same idea as a shared transit trip showing "3 stops left", not a dot on a map).
enum NavShareService {
    /// Matches the server's NAV_MODES exactly.
    enum Mode: String { case automobile, scooter, walking }

    private struct CreateBody: Encodable {
        struct Nav: Encodable { let mode: String; let destinationName: String }
        let title: String
        let kind = "nav"
        let ttlHours: Int
        let nav: Nav
        /// "安全分享": off unless the sharer explicitly turns it on for this one link (see
        /// ShareTripService.Body — same flag, same meaning, for either kind of share).
        let shareLiveLocation: Bool
    }

    /// A link that exists the moment the button is pressed — reuses ShareTripService.Prepared
    /// (token+url+body) so this plugs straight into the existing InstantShare.run flow: the
    /// share sheet opens at once, upload/retry happens in the background.
    static func prepare(destinationName: String, mode: Mode, ttlHours: Int = 6, shareLiveLocation: Bool = false) -> Result<ShareTripService.Prepared, ShareTripService.Failure> {
        let token = ShareLink.makeToken()
        guard let url = ShareLink.url(token: token) else { return .failure(.backendUnavailable) }
        let body = CreateBody(title: "前往\(destinationName)", ttlHours: ttlHours, nav: .init(mode: mode.rawValue, destinationName: destinationName), shareLiveLocation: shareLiveLocation)
        guard let data = try? JSONEncoder().encode(body) else { return .failure(.backendUnavailable) }
        return .success(ShareTripService.Prepared(token: token, url: url, body: data, shareLiveLocation: shareLiveLocation))
    }

    private struct ProgressBody: Encodable {
        let remainingMeters: Double
        let etaSeconds: Double
        let instruction: String?
        let arrived: Bool
    }

    /// Pushed every so often while navigating (see InAppNavigationView's periodic call). Fire and
    /// forget — a dropped update just means the shared page looks a few seconds staler than usual,
    /// never worth retrying or blocking the UI over.
    static func pushProgress(token: String, remainingMeters: Double, etaSeconds: Double, instruction: String?, arrived: Bool) {
        guard let base = BackendConfig.baseURL, remainingMeters.isFinite, etaSeconds.isFinite else { return }
        var req = URLRequest(url: base.appendingPathComponent("v1/shares/\(token)/progress"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(ProgressBody(
            remainingMeters: max(0, remainingMeters), etaSeconds: max(0, etaSeconds), instruction: instruction, arrived: arrived
        ))
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
