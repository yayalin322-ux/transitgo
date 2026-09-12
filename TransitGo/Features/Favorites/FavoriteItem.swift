import Foundation
import SwiftData

enum FavoriteKind: String {
    case busRoute
    case busStop
    case bikeStation
}

@Model
final class FavoriteItem {
    var kind: String
    var city: String
    var routeName: String
    var title: String
    var subtitle: String
    var createdAt: Date
    /// Coordinate for point favorites (bike/bus stops). 0,0 = none.
    var lat: Double = 0
    var lon: Double = 0

    init(kind: String, city: String, routeName: String, title: String, subtitle: String,
         lat: Double = 0, lon: Double = 0) {
        self.kind = kind
        self.city = city
        self.routeName = routeName
        self.title = title
        self.subtitle = subtitle
        self.lat = lat
        self.lon = lon
        self.createdAt = .now
    }

    /// `city` stores a `BusScope.storageKey` (e.g. "City:Taipei" or "InterCity").
    var busScope: BusScope? { BusScope(storageKey: city) }
}
