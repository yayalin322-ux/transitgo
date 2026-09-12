import Foundation
import CoreLocation

struct BikeService {
    static let shared = BikeService()
    private let client = TDXClient.shared

    func nearbyStations(city: BikeCity, near coord: CLLocationCoordinate2D, radius: Int = 500) async throws -> [BikeStation] {
        try await client.get(
            "v2/Bike/Station/City/\(city.rawValue)",
            query: [
                "$spatialFilter": "nearby(\(coord.latitude),\(coord.longitude),\(radius))",
                "$select": "StationUID,StationName,StationPosition,StationAddress,BikesCapacity",
                "$top": "250",
            ]
        )
    }

    /// Every station in a city, no spatial filter — for the on-device search catalog
    /// (station lists barely change, so this is cached long-term by `BikeStationCatalog`).
    func allStations(city: BikeCity) async throws -> [BikeStation] {
        try await client.get(
            "v2/Bike/Station/City/\(city.rawValue)",
            query: [
                "$select": "StationUID,StationName,StationPosition,StationAddress,BikesCapacity",
                "$top": "3000",
            ]
        )
    }

    func availability(city: BikeCity, stationUIDs: [String]) async throws -> [String: BikeAvailability] {
        guard !stationUIDs.isEmpty else { return [:] }
        // A few stations → targeted filter; many → grab the whole city (cached) and index.
        if stationUIDs.count <= 40 {
            let filter = stationUIDs.map { "StationUID eq '\($0)'" }.joined(separator: " or ")
            let list: [BikeAvailability] = try await client.get(
                "v2/Bike/Availability/City/\(city.rawValue)",
                query: ["$filter": filter, "$top": "40"]
            )
            return Dictionary(list.map { ($0.stationUID, $0) }, uniquingKeysWith: { _, b in b })
        }
        let all = try await cityAvailability(city: city)
        let wanted = Set(stationUIDs)
        return all.filter { wanted.contains($0.key) }
    }

    /// Whole-city availability, indexed by StationUID. Cached by `TDXCache`.
    func cityAvailability(city: BikeCity) async throws -> [String: BikeAvailability] {
        let list: [BikeAvailability] = try await client.get(
            "v2/Bike/Availability/City/\(city.rawValue)",
            query: ["$top": "2000"]
        )
        return Dictionary(list.map { ($0.stationUID, $0) }, uniquingKeysWith: { _, b in b })
    }

    func availability(city: BikeCity, stationUID: String) async throws -> BikeAvailability? {
        let list: [BikeAvailability] = try await client.get(
            "v2/Bike/Availability/City/\(city.rawValue)",
            query: ["$filter": "StationUID eq '\(stationUID)'"]
        )
        return list.first
    }

    /// Nearby stations joined with live availability, nearest first.
    /// Fetches the station list and the whole-city availability *concurrently*.
    func nearbyLive(city: BikeCity, near coord: CLLocationCoordinate2D, radius: Int = 500) async throws -> [BikeStationLive] {
        async let stationsTask = nearbyStations(city: city, near: coord, radius: radius)
        async let availTask = try? await cityAvailability(city: city)
        let stations = try await stationsTask
        var avail = await availTask ?? [:]
        if avail.isEmpty {
            avail = (try? await availability(city: city, stationUIDs: stations.map(\.stationUID))) ?? [:]
        }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return stations.map { s in
            var live = BikeStationLive(station: s, availability: avail[s.stationUID], city: city)
            if let c = s.coordinate {
                live.distance = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
            }
            return live
        }
        .sorted { $0.distance < $1.distance }
    }

    /// Nearby stations across several cities at once, merged and sorted — lets a map
    /// sweep near a county border pull both sides without knowing which one it's in.
    func nearbyLive(cities: [BikeCity], near coord: CLLocationCoordinate2D, radius: Int = 500) async -> [BikeStationLive] {
        await withTaskGroup(of: [BikeStationLive].self) { group in
            for city in cities {
                group.addTask { (try? await self.nearbyLive(city: city, near: coord, radius: radius)) ?? [] }
            }
            var out: [BikeStationLive] = []
            for await batch in group { out += batch }
            return out.sorted { $0.distance < $1.distance }
        }
    }
}
