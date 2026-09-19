import Foundation
import CoreLocation

/// Superseded by `BikeStationService`, which nearby lists, the map, availability and route planning
/// now all share. Kept (not deleted) so nothing that still names it breaks; new code must not use it.
@available(*, deprecated, message: "Use BikeStationService — one YouBike service for nearby, availability and routing candidates.")
enum SharedBikeService {
    static func nearby(near coord: CLLocationCoordinate2D, radius: Int = 900, city: BikeCity?) async -> [BikeStationLive]? {
        await BikeStationService.nearby(near: coord, radius: radius, city: city)
    }

    static func search(keyword: String, limit: Int = 20) async -> [BikeStationLive]? {
        await BikeStationService.search(keyword: keyword, limit: limit)
    }
}
