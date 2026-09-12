import Foundation

/// On-device, nationwide YouBike station-name index. Station lists barely change day to
/// day, so each city's list is fetched once (in parallel, across all `BikeCity` cases)
/// and cached to disk for hours — after the first search ever, searching a station name
/// from anywhere in Taiwan is instant and needs no network round trip.
actor BikeStationCatalog {
    static let shared = BikeStationCatalog()

    private var memory: [BikeCity: [BikeStation]] = [:]
    private let ttl: TimeInterval = 12 * 3600

    private struct Snapshot: Codable {
        let stations: [BikeStation]
        let at: Date
    }

    private var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BikeCatalog", isDirectory: true)
    }
    private func fileURL(_ city: BikeCity) -> URL {
        dir.appendingPathComponent("\(city.rawValue).json")
    }

    /// Fetches in flight, keyed by city — a search and the app-launch prewarm can race
    /// to fetch the same city; this makes the second caller just await the first's result
    /// instead of firing a duplicate request.
    private var inflight: [BikeCity: Task<[BikeStation], Never>] = [:]

    func ensureFresh(_ city: BikeCity) async -> [BikeStation] {
        if let cached = memory[city] { return cached }
        if let disk = loadDisk(city), Date().timeIntervalSince(disk.at) < ttl {
            memory[city] = disk.stations
            return disk.stations
        }
        if let existing = inflight[city] { return await existing.value }
        let task = Task<[BikeStation], Never> {
            // One retry after a short backoff — a nationwide fan-out can trip TDX's
            // rate limiter for a city or two even with capped concurrency below.
            if let fetched = try? await BikeService.shared.allStations(city: city) {
                return fetched
            }
            try? await Task.sleep(for: .seconds(2))
            return (try? await BikeService.shared.allStations(city: city)) ?? []
        }
        inflight[city] = task
        let fetched = await task.value
        inflight[city] = nil
        guard !fetched.isEmpty else { return memory[city] ?? loadDisk(city)?.stations ?? [] }
        memory[city] = fetched
        saveDisk(city, fetched)
        return fetched
    }

    private func loadDisk(_ city: BikeCity) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(city)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func saveDisk(_ city: BikeCity, _ stations: [BikeStation]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snap = Snapshot(stations: stations, at: Date())
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL(city), options: .atomic)
        }
    }

    /// Nationwide substring search across every TDX bike city. Fetches in small waves
    /// (not all 17 at once) so a cold catalog doesn't trip TDX's rate limiter and quietly
    /// come back covering only whichever couple of cities happened to succeed.
    func search(_ keyword: String) async -> [(city: BikeCity, station: BikeStation)] {
        let needle = keyword.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var out: [(BikeCity, BikeStation)] = []
        for chunk in BikeCity.allCases.chunked(into: 4) {
            let results: [(BikeCity, BikeStation)] = await withTaskGroup(of: [(BikeCity, BikeStation)].self) { group in
                for city in chunk {
                    group.addTask {
                        let stations = await self.ensureFresh(city)
                        return stations
                            .filter { $0.name.localizedCaseInsensitiveContains(needle) }
                            .map { (city, $0) }
                    }
                }
                var batchOut: [(BikeCity, BikeStation)] = []
                for await batch in group { batchOut += batch }
                return batchOut
            }
            out += results
        }
        return out
    }

    /// Warms every city's catalog on disk, a few at a time, in the background — so by
    /// the time the user actually searches, most (ideally all) of Taiwan is already cached.
    func prewarmAll() async {
        for chunk in BikeCity.allCases.chunked(into: 3) {
            await withTaskGroup(of: Void.self) { group in
                for city in chunk { group.addTask { _ = await self.ensureFresh(city) } }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
