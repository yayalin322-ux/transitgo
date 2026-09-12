import Foundation
import CoreLocation

struct BikeStation: Codable, Identifiable, Hashable {
    let stationUID: String
    let stationName: LocalizedName
    let stationPosition: GeoPoint?
    let stationAddress: LocalizedName?
    let bikesCapacity: Int?

    var id: String { stationUID }
    var name: String {
        stationName.display
            .replacingOccurrences(of: "YouBike2.0_", with: "")
            .replacingOccurrences(of: "YouBike1.0_", with: "")
    }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = stationPosition?.lat, let lon = stationPosition?.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case stationUID = "StationUID"
        case stationName = "StationName"
        case stationPosition = "StationPosition"
        case stationAddress = "StationAddress"
        case bikesCapacity = "BikesCapacity"
    }
}

struct BikeAvailability: Codable, Identifiable {
    let stationUID: String
    let serviceStatus: Int?
    let availableRentBikes: Int?
    let availableReturnBikes: Int?
    let availableRentBikesDetail: BikeDetail?
    let srcUpdateTime: String?

    var id: String { stationUID }
    var inService: Bool { (serviceStatus ?? 0) == 1 }

    var updatedAt: Date? {
        guard let s = srcUpdateTime else { return nil }
        return ISO8601DateFormatter().date(from: s)
            ?? ISO8601DateFormatter.withFractional.date(from: s)
    }

    /// "可租可停" / "無車可借" / "車位已滿" / "暫停營運"
    var statusText: String {
        if !inService { return "暫停營運" }
        let rent = availableRentBikes ?? 0, ret = availableReturnBikes ?? 0
        if rent == 0 { return "無車可借" }
        if ret == 0 { return "車位已滿" }
        return "可租可停"
    }

    enum CodingKeys: String, CodingKey {
        case stationUID = "StationUID"
        case serviceStatus = "ServiceStatus"
        case availableRentBikes = "AvailableRentBikes"
        case availableReturnBikes = "AvailableReturnBikes"
        case availableRentBikesDetail = "AvailableRentBikesDetail"
        case srcUpdateTime = "SrcUpdateTime"
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct BikeDetail: Codable {
    let generalBikes: Int?
    let electricBikes: Int?
    enum CodingKeys: String, CodingKey {
        case generalBikes = "GeneralBikes"
        case electricBikes = "ElectricBikes"
    }
}

/// A station joined with its live availability, for list + map.
struct BikeStationLive: Identifiable {
    let station: BikeStation
    var availability: BikeAvailability? = nil
    var distance: CLLocationDistance = .greatestFiniteMagnitude
    /// Which TDX city this came from — needed to keep tracking/favoriting/refresh calls
    /// scoped correctly once a station from a *different* city gets merged in by the
    /// cross-city sweep (nationwide YouBike browsing pans across county borders).
    var city: BikeCity
    var id: String { station.stationUID }

    var rent: Int { availability?.availableRentBikes ?? 0 }
    var ret: Int { availability?.availableReturnBikes ?? 0 }
}

/// TDX Bike cities (subset).
enum BikeCity: String, CaseIterable, Identifiable {
    case taipei = "Taipei"
    case newTaipei = "NewTaipei"
    case taoyuan = "Taoyuan"
    case hsinchu = "Hsinchu"
    case hsinchuCounty = "HsinchuCounty"
    case miaoliCounty = "MiaoliCounty"
    case taichung = "Taichung"
    case changhuaCounty = "ChanghuaCounty"
    case chiayi = "Chiayi"
    case chiayiCounty = "ChiayiCounty"
    case tainan = "Tainan"
    case kaohsiung = "Kaohsiung"
    case pingtungCounty = "PingtungCounty"
    case yilanCounty = "YilanCounty"
    case hualienCounty = "HualienCounty"
    case taitungCounty = "TaitungCounty"
    case kinmenCounty = "KinmenCounty"

    /// Rough town-centre coordinate — just enough to rank "which city is this map
    /// point probably in" so panning across a county border can switch TDX city scope
    /// without a full reverse-geocode round trip.
    var centroid: CLLocationCoordinate2D {
        switch self {
        case .taipei: return .init(latitude: 25.0375, longitude: 121.5637)
        case .newTaipei: return .init(latitude: 25.0169, longitude: 121.4627)
        case .taoyuan: return .init(latitude: 24.9936, longitude: 121.3010)
        case .hsinchu: return .init(latitude: 24.8138, longitude: 120.9675)
        case .hsinchuCounty: return .init(latitude: 24.8388, longitude: 121.0177)
        case .miaoliCounty: return .init(latitude: 24.5602, longitude: 120.8214)
        case .taichung: return .init(latitude: 24.1477, longitude: 120.6736)
        case .changhuaCounty: return .init(latitude: 24.0518, longitude: 120.5161)
        case .chiayi: return .init(latitude: 23.4801, longitude: 120.4491)
        case .chiayiCounty: return .init(latitude: 23.4518, longitude: 120.2555)
        case .tainan: return .init(latitude: 22.9998, longitude: 120.2269)
        case .kaohsiung: return .init(latitude: 22.6273, longitude: 120.3014)
        case .pingtungCounty: return .init(latitude: 22.5519, longitude: 120.5487)
        case .yilanCounty: return .init(latitude: 24.7021, longitude: 121.7377)
        case .hualienCounty: return .init(latitude: 23.9871, longitude: 121.6015)
        case .taitungCounty: return .init(latitude: 22.7583, longitude: 121.1444)
        case .kinmenCounty: return .init(latitude: 24.4324, longitude: 118.3170)
        }
    }

    /// The `count` TDX bike cities whose centroid is nearest `coord` — used so a map
    /// pan/sweep can pick up the right city (or two, near a border) as it moves.
    static func nearest(to coord: CLLocationCoordinate2D, count: Int = 2) -> [BikeCity] {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return allCases.sorted { a, b in
            let da = CLLocation(latitude: a.centroid.latitude, longitude: a.centroid.longitude).distance(from: here)
            let db = CLLocation(latitude: b.centroid.latitude, longitude: b.centroid.longitude).distance(from: here)
            return da < db
        }
        .prefix(count)
        .map { $0 }
    }

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .taipei: return "臺北市"
        case .newTaipei: return "新北市"
        case .taoyuan: return "桃園市"
        case .hsinchu: return "新竹市"
        case .hsinchuCounty: return "新竹縣"
        case .miaoliCounty: return "苗栗縣"
        case .taichung: return "臺中市"
        case .changhuaCounty: return "彰化縣"
        case .chiayi: return "嘉義市"
        case .chiayiCounty: return "嘉義縣"
        case .tainan: return "臺南市"
        case .kaohsiung: return "高雄市"
        case .pingtungCounty: return "屏東縣"
        case .yilanCounty: return "宜蘭縣"
        case .hualienCounty: return "花蓮縣"
        case .taitungCounty: return "臺東縣"
        case .kinmenCounty: return "金門縣"
        }
    }
}
