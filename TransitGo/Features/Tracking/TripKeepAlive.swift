import Foundation
import CoreLocation

/// Keeps the app running in the background while a trip is being tracked, so the
/// poll loop can keep pushing `Activity.update(...)` to the Live Activity.
///
/// With a free Apple team we can't use APNs push for Live Activities, so the only
/// way to update one while backgrounded is to keep the process alive — here via
/// low-power continuous location updates (the standard transit-tracker technique).
/// Ref-counted: the last tracker to stop releases it.
@MainActor
final class TripKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = TripKeepAlive()

    private let manager = CLLocationManager()
    private var count = 0

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func acquire() {
        count += 1
        guard count == 1 else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func release() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // We don't need the fixes themselves — just keeping updates active keeps us alive.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
