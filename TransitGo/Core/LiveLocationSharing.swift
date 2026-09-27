import Foundation
import CoreLocation

/// "安全分享": pushes the phone's own coordinate to the backend for ONE specific share link —
/// only ever a link the sharer explicitly opted in on when creating it (see the
/// `shareLiveLocation` flag on ShareTripService.Body / NavShareService's create body). A normal
/// share never calls this at all; the server itself also refuses these pushes for any token that
/// wasn't created with the flag on (see updateShareLocation on the backend).
enum LiveLocationSharing {
    /// Minimum gap between pushes — same cadence idea as nav progress, so a chatty
    /// CLLocationManager delegate callback can't spam the backend.
    static let minInterval: TimeInterval = 8

    private struct Body: Encodable { let lat: Double; let lon: Double }

    /// Fire and forget, like NavShareService.pushProgress — a dropped update just means the
    /// viewer's map looks a little staler, never worth retrying or blocking the UI over.
    static func push(token: String, coordinate: CLLocationCoordinate2D) {
        guard let base = BackendConfig.baseURL, coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }
        var req = URLRequest(url: base.appendingPathComponent("v1/shares/\(token)/location"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(lat: coordinate.latitude, lon: coordinate.longitude))
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}

/// Owns a dedicated, moderate-accuracy CLLocationManager and throttles pushes through
/// `LiveLocationSharing`. For a screen with no continuous location tracker of its own (the
/// trip/TRA/HSR share sheet). The in-app navigation screen instead feeds its own already-running,
/// navigation-grade tracker's fixes through `LiveLocationSharing.push` directly (see
/// InAppNavigationView) rather than running a second CLLocationManager alongside it.
@MainActor
@Observable
final class LiveLocationPusher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var lastPushAt: Date = .distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
    }

    /// Starts pushing the phone's location, throttled, onto this one token — call only after the
    /// sharer explicitly opted in for this specific link.
    func start(token: String) {
        self.token = token
        lastPushAt = .distantPast
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    /// Stops pushing. Call when the sharer turns 安全分享 off, leaves the screen, or the
    /// trip/navigation this link was for has ended — sharing live location is never left running
    /// past the moment it's actually useful.
    func stop() {
        token = nil
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if (status == .authorizedWhenInUse || status == .authorizedAlways), self.token != nil {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            guard let token = self.token else { return }
            guard Date().timeIntervalSince(self.lastPushAt) >= LiveLocationSharing.minInterval else { return }
            self.lastPushAt = Date()
            LiveLocationSharing.push(token: token, coordinate: loc.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
