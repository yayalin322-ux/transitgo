import Foundation

/// TDX `NameType` — most names come as `{ "Zh_tw": ..., "En": ... }`.
struct LocalizedName: Codable, Hashable {
    let zhTw: String?
    let en: String?

    enum CodingKeys: String, CodingKey {
        case zhTw = "Zh_tw"
        case en = "En"
    }

    var display: String { zhTw ?? en ?? "" }
}

/// TDX `PointType`.
struct GeoPoint: Codable, Hashable {
    let lat: Double?
    let lon: Double?

    enum CodingKeys: String, CodingKey {
        case lat = "PositionLat"
        case lon = "PositionLon"
    }
}
