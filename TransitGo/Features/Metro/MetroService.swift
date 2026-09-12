import Foundation
import CoreLocation

@MainActor
@Observable
final class MetroStationStore {
    static let shared = MetroStationStore()
    private var cache: [String: [MetroStation]] = [:]

    func stations(operator op: MetroOperator) async -> [MetroStation] {
        if let c = cache[op.rawValue] { return c }
        let list: [MetroStation] = (try? await TDXClient.shared.get(
            "v2/Rail/Metro/Station/\(op.rawValue)",
            query: ["$select": "StationUID,StationID,StationName,StationPosition"]
        )) ?? []
        cache[op.rawValue] = list
        return list
    }
}

struct MetroService {
    static let shared = MetroService()
    private let client = TDXClient.shared

    func lines(operator op: MetroOperator) async throws -> [MetroLine] {
        try await client.get("v2/Rail/Metro/Line/\(op.rawValue)", query: ["$select": "LineID,LineName,LineColor"])
    }

    func stationsOfLine(operator op: MetroOperator) async throws -> [MetroStationOfLine] {
        try await client.get("v2/Rail/Metro/StationOfLine/\(op.rawValue)")
    }

    /// Real-time arrivals; optionally filtered to one station.
    func liveBoard(operator op: MetroOperator, stationID: String? = nil) async throws -> [MetroLiveBoard] {
        var query: [String: String] = ["$top": "200"]
        if let stationID {
            query["$filter"] = "StationID eq '\(stationID)'"
        }
        let list: [MetroLiveBoard] = try await client.get(
            "v2/Rail/Metro/LiveBoard/\(op.rawValue)", query: query
        )
        return list.sorted { ($0.estimateTime ?? 99) < ($1.estimateTime ?? 99) }
    }

    /// Non-normal service alerts only (TDX always includes a baseline "正常營運" row).
    func alerts(operator op: MetroOperator) async throws -> [MetroAlertItem] {
        let resp: MetroAlertResponse = try await client.get("v2/Rail/Metro/Alert/\(op.rawValue)")
        return resp.alerts.filter { !$0.isNormal }
    }

    /// First/last train times for one station, every direction.
    func firstLastTimetable(operator op: MetroOperator, stationID: String) async throws -> [MetroFirstLastTrip] {
        try await client.get(
            "v2/Rail/Metro/FirstLastTimetable/\(op.rawValue)",
            query: ["$filter": "StationID eq '\(stationID)'"]
        )
    }

    /// Fare rows for one O/D pair. TDX has no path-based OD lookup for Metro — it's a
    /// `$filter` over the operator-wide fare table.
    func odFare(operator op: MetroOperator, from: String, to: String) async throws -> MetroODFareRow? {
        let rows: [MetroODFareRow] = try await client.get(
            "v2/Rail/Metro/ODFare/\(op.rawValue)",
            query: ["$filter": "OriginStationID eq '\(from)' and DestinationStationID eq '\(to)'"]
        )
        return rows.first
    }

    /// Every station-to-station running-time segment for one line — used to sum up an
    /// estimated ride duration between two stations on that line.
    func travelSegments(operator op: MetroOperator, lineID: String) async throws -> [MetroS2SSegment] {
        let routes: [MetroS2SRoute] = try await client.get(
            "v2/Rail/Metro/S2STravelTime/\(op.rawValue)",
            query: ["$filter": "LineID eq '\(lineID)'"]
        )
        return routes.flatMap(\.travelTimes)
    }

    func nearbyStations(operator op: MetroOperator, near coord: CLLocationCoordinate2D, limit: Int = 8) async -> [MetroStation] {
        let all = await MetroStationStore.shared.stations(operator: op)
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return all
            .compactMap { s -> (MetroStation, CLLocationDistance)? in
                guard let c = s.coordinate else { return nil }
                return (s, CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here))
            }
            .filter { $0.1 < 1200 }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
