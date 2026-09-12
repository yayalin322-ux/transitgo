import Foundation
import MapKit

/// Rough door-to-door times for the alternatives to public transit, shown when the
/// transfer planner can't find a transit itinerary — "no bus for this" shouldn't mean
/// dead end, it should mean "here's how long driving/riding/biking/walking takes instead".
struct TravelTimeOptions {
    let driveMinutes: Int?
    let scooterMinutes: Int?
    let bikeMinutes: Int?          // YouBike — derived, see estimate() below
    let ownBikeMinutes: Int?       // a bike you already have — real MKDirections .cycling route
    let walkMinutes: Int?

    var isEmpty: Bool {
        driveMinutes == nil && scooterMinutes == nil && bikeMinutes == nil
        && ownBikeMinutes == nil && walkMinutes == nil
    }
}

enum TravelTimeEstimator {
    /// MapKit has no dedicated "scooter" or "bike-share" transport type, so those two are
    /// derived estimates (scooter from the driving route, YouBike from the walking route's
    /// distance) rather than real routed times — labelled as such wherever they're shown.
    /// A regular bike you already own *does* get a real routed time (`.cycling`, iOS 17+).
    static func estimate(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> TravelTimeOptions {
        async let driveTask = route(from: origin, to: destination, type: .automobile)
        async let walkTask = route(from: origin, to: destination, type: .walking)
        async let cycleTask = route(from: origin, to: destination, type: .cycling)
        let drive = await driveTask
        let walk = await walkTask
        let cycle = await cycleTask

        let driveMin = drive.map { Int(($0.expectedTravelTime / 60).rounded()) }
        let scooterMin = driveMin.map { max(1, Int((Double($0) * 0.8).rounded(.up))) }   // filters through traffic
        // Walking uses the *learned* personal pace against the routed distance, not Apple's
        // generic walking-speed assumption — see WalkingSpeedLearner (fed by real sessions).
        let walkMin = walk.map { WalkingSpeedLearner.estimatedMinutes(forMeters: $0.distance) }
        let ownBikeMin = cycle.map { Int(($0.expectedTravelTime / 60).rounded()) }
        let bikeMin: Int? = walk.map { r in
            let hours = (r.distance / 1000) / 15.0   // ~15 km/h average including stops
            return max(1, Int((hours * 60).rounded()) + 2)   // +2 min to unlock/dock a YouBike
        }
        return TravelTimeOptions(driveMinutes: driveMin, scooterMinutes: scooterMin,
                                 bikeMinutes: bikeMin, ownBikeMinutes: ownBikeMin, walkMinutes: walkMin)
    }

    /// Best-effort geocode for when only a place *name* is known (e.g. a TRA station,
    /// which this app doesn't have coordinates for) — searches it as a landmark.
    static func geocode(_ name: String, near: CLLocationCoordinate2D) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: near, span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5))
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }

    private static func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, type: MKDirectionsTransportType) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = type
        guard let response = try? await MKDirections(request: request).calculate() else { return nil }
        return response.routes.first
    }
}
