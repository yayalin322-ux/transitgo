import Foundation
import CoreLocation

/// "住家"/"公司" quick-select locations — Google-Maps-style shortcuts so the user doesn't
/// have to re-search the same address every time. UserDefaults-backed (not SwiftData —
/// there are only ever two of these, no list UI needed) so it's local-only, no schema
/// migration risk, and trivially simple.
struct SavedPlace: Codable, Equatable {
    var name: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum SavedPlaceRole: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case home, work
    var label: String { self == .home ? "住家" : "公司" }
    var icon: String { self == .home ? "house.fill" : "briefcase.fill" }
}

enum SavedPlaceStore {
    private static func key(_ role: SavedPlaceRole) -> String { "savedPlace.\(role.rawValue)" }

    static func get(_ role: SavedPlaceRole) -> SavedPlace? {
        guard let data = UserDefaults.standard.data(forKey: key(role)) else { return nil }
        return try? JSONDecoder().decode(SavedPlace.self, from: data)
    }

    static func set(_ role: SavedPlaceRole, name: String, coordinate: CLLocationCoordinate2D) {
        let place = SavedPlace(name: name, lat: coordinate.latitude, lon: coordinate.longitude)
        guard let data = try? JSONEncoder().encode(place) else { return }
        UserDefaults.standard.set(data, forKey: key(role))
    }

    static func clear(_ role: SavedPlaceRole) {
        UserDefaults.standard.removeObject(forKey: key(role))
    }
}
