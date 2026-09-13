import Foundation
import CoreLocation

/// A geo-tagged photo of a real place along the way — currently sourced from Hsinchu
/// City's open-data point list (station/spot name + coordinates + a real photo URL, no
/// auth, no rate limit). Only real, published data — nothing generated or guessed.
struct RoutePhotoSpot: Identifiable {
    let name: String
    let lat: Double
    let lon: Double
    let imageURL: URL
    let address: String?
    var id: String { "\(name)_\(lat)_\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum RoutePhotoService {
    private struct Row: Decodable {
        let name: String?
        let lat: String?
        let lon: String?
        let image: String?
        let address: String?
        enum CodingKeys: String, CodingKey {
            case name = "站點名稱", lat = "緯度", lon = "經度", image = "圖片", address = "站點位置"
        }
    }

    private static var cached: [RoutePhotoSpot]?
    private static let sourceURL = URL(string: "https://opendata.hccg.gov.tw/OpenDataFileHit.ashx?ID=9CCC6648E34E2C36&u=77DFE16E459DFCE30371C36CCE30AFF2620C9FA93F99248767110C1E4071F137C5FBEE507EBE009F2A6AFAF641DA977A4EF2D5AA4DEE76CC0AF6008E48ED1F089BEC5004D1985A4BCA289E92E4BD1DE813108814A4DCE4F2C2BDEC30C68238CAB9F2A99E574FFC6EA18EE3E9E90A123C")!

    /// Fetched once per app session (this data barely changes) — nil means unreachable,
    /// not "no photos exist here"; callers should just skip the layer, not show an error.
    static func allSpots() async -> [RoutePhotoSpot]? {
        if let cached { return cached }
        guard let (data, resp) = try? await URLSession.shared.data(from: sourceURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        let spots = rows.compactMap { r -> RoutePhotoSpot? in
            guard let name = r.name, let latStr = r.lat, let lonStr = r.lon,
                  let lat = Double(latStr), let lon = Double(lonStr),
                  let imageStr = r.image, let url = URL(string: imageStr) else { return nil }
            return RoutePhotoSpot(name: name, lat: lat, lon: lon, imageURL: url, address: r.address)
        }
        cached = spots
        return spots
    }

    /// Spots within `radius` metres of `coordinate` — cheap enough to call as the user
    /// moves since `allSpots()` only hits the network once.
    static func nearby(_ coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> [RoutePhotoSpot] {
        guard let all = await allSpots() else { return [] }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return all.filter { here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) <= radius }
    }
}
