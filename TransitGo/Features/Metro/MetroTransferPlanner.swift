import Foundation
import CoreLocation

struct MetroLeg: Identifiable, Hashable {
    let id = UUID()
    let lineName: String
    let fromStation: MetroStation
    let toStation: MetroStation

    static func == (l: MetroLeg, r: MetroLeg) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct MetroItinerary: Identifiable {
    let id = UUID()
    let legs: [MetroLeg]
}

/// Metro lines are simple loops/lines (no branches the way bus routes have), so "can I get
/// there" is just "do both stations sit on the same line" — no transfer search needed for
/// a single-operator system. Cross-operator or cross-line transfers aren't attempted.
enum MetroTransferPlanner {
    static func plan(operator op: MetroOperator, from origin: MetroStation, to destination: MetroStation) async -> [MetroItinerary] {
        guard origin.stationID != destination.stationID,
              let stationsOfLines = try? await MetroService.shared.stationsOfLine(operator: op),
              let lines = try? await MetroService.shared.lines(operator: op) else { return [] }
        let lineNames = Dictionary(uniqueKeysWithValues: lines.map { ($0.lineID, $0.name) })

        var results: [MetroItinerary] = []
        for sol in stationsOfLines {
            let ids = Set(sol.stations.map(\.stationID))
            guard ids.contains(origin.stationID), ids.contains(destination.stationID) else { continue }
            let name = lineNames[sol.lineID] ?? sol.lineID
            results.append(MetroItinerary(legs: [MetroLeg(lineName: name, fromStation: origin, toStation: destination)]))
        }
        return results
    }

    /// Coordinate-based version for the unified planner — finds metro stations within
    /// `radius` of each point (not a hand-picked exact station) and checks same-line
    /// reachability, the way a user would actually approach "closest station to me" and
    /// "closest station to where I'm going".
    static func planNearby(
        operator op: MetroOperator, from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
        radius: CLLocationDistance = 800
    ) async -> [MetroItinerary] {
        let stations = await MetroStationStore.shared.stations(operator: op)
        func nearby(_ coord: CLLocationCoordinate2D) -> [MetroStation] {
            let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            return stations.filter {
                guard let c = $0.coordinate else { return false }
                return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here) <= radius
            }
        }
        let originStations = nearby(origin)
        let destStations = nearby(destination)
        guard !originStations.isEmpty, !destStations.isEmpty,
              let stationsOfLines = try? await MetroService.shared.stationsOfLine(operator: op),
              let lines = try? await MetroService.shared.lines(operator: op) else { return [] }
        let lineNames = Dictionary(uniqueKeysWithValues: lines.map { ($0.lineID, $0.name) })

        var results: [MetroItinerary] = []
        for sol in stationsOfLines {
            let ids = Set(sol.stations.map(\.stationID))
            for o in originStations where ids.contains(o.stationID) {
                for d in destStations where ids.contains(d.stationID) && d.stationID != o.stationID {
                    let name = lineNames[sol.lineID] ?? sol.lineID
                    results.append(MetroItinerary(legs: [MetroLeg(lineName: name, fromStation: o, toStation: d)]))
                }
            }
        }
        return Array(results.prefix(3))
    }
}
