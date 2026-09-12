import Foundation
import CoreLocation

/// Last successful nearby-YouBike snapshot per city, on disk. Lets the map show
/// something *immediately* on open (stale, flagged) while a fresh fetch runs.
enum BikeCache {
    struct Snapshot: Codable {
        var stations: [BikeStation]
        var availability: [BikeAvailability]
        var lat: Double
        var lon: Double
        var at: Date
    }

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BikeCache", isDirectory: true)
    }
    private static func url(_ city: BikeCity) -> URL {
        dir.appendingPathComponent("\(city.rawValue).json")
    }

    /// Groups stations by their *own* city before saving — needed now that one sweep can
    /// return stations from more than one TDX city (nationwide / cross-border browsing).
    static func saveGrouped(_ live: [BikeStationLive], center: CLLocationCoordinate2D) {
        for (city, group) in Dictionary(grouping: live, by: \.city) {
            save(city, live: group, center: center)
        }
    }

    static func save(_ city: BikeCity, live: [BikeStationLive], center: CLLocationCoordinate2D) {
        let snap = Snapshot(
            stations: live.map(\.station),
            availability: live.compactMap(\.availability),
            lat: center.latitude, lon: center.longitude, at: Date()
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: url(city), options: .atomic)
        }
    }

    static func load(_ city: BikeCity) -> (live: [BikeStationLive], center: CLLocationCoordinate2D, age: TimeInterval)? {
        guard let data = try? Data(contentsOf: url(city)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let byUID = Dictionary(snap.availability.map { ($0.stationUID, $0) }, uniquingKeysWith: { a, _ in a })
        let center = CLLocationCoordinate2D(latitude: snap.lat, longitude: snap.lon)
        let here = CLLocation(latitude: snap.lat, longitude: snap.lon)
        let live = snap.stations.map { s -> BikeStationLive in
            var l = BikeStationLive(station: s, availability: byUID[s.stationUID], city: city)
            if let c = s.coordinate {
                l.distance = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
            }
            return l
        }.sorted { $0.distance < $1.distance }
        return (live, center, Date().timeIntervalSince(snap.at))
    }
}
