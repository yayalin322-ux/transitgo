import AppIntents
import Foundation

/// A 台鐵 station as a picker choice, shared by the widget's configuration and Siri. The list comes from the backend
/// (which keeps it cached for a day) so no device asks TDX for it, and is remembered on the device so the picker still
/// works when the backend is briefly unreachable.
struct TRAStationEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "台鐵車站" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = TRAStationEntityQuery()
}

struct TRAStationEntityQuery: EntityStringQuery {
    private static let cacheKey = "traStationList.v1"

    static func catalog() async -> [TRAStationEntity] {
        let defaults = UserDefaults.standard
        if let fresh = try? await RailBoardService.stations(), !fresh.isEmpty {
            if let data = try? JSONEncoder().encode(fresh.map { [$0.id, $0.name] }) { defaults.set(data, forKey: cacheKey) }
            return fresh.map { TRAStationEntity(id: $0.id, name: $0.name) }
        }
        if let data = defaults.data(forKey: cacheKey), let pairs = try? JSONDecoder().decode([[String]].self, from: data) {
            return pairs.compactMap { $0.count == 2 ? TRAStationEntity(id: $0[0], name: $0[1]) : nil }
        }
        return []
    }

    func entities(for identifiers: [String]) async throws -> [TRAStationEntity] {
        await Self.catalog().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TRAStationEntity] {
        let all = await Self.catalog()
        // "台北" and "臺北" are the same station; people type either.
        let q = Self.normalized(string)
        guard !q.isEmpty else { return all }
        return all.filter { Self.normalized($0.name).contains(q) }
    }

    func suggestedEntities() async throws -> [TRAStationEntity] { await Self.catalog() }

    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "台", with: "臺").replacingOccurrences(of: "站", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// 北上 / 南下 as a Siri and widget choice.
enum TrainHeadingOption: String, AppEnum {
    case north, south
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "方向" }
    static var caseDisplayRepresentations: [TrainHeadingOption: DisplayRepresentation] { [.north: "北上", .south: "南下"] }
    var heading: RailHeading { self == .north ? .north : .south }
}
