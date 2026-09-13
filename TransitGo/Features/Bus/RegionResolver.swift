import Foundation
import CoreLocation

/// The transit systems available where the user currently is.
struct LocalRegion: Equatable {
    var areaName: String            // e.g. 臺北市 / 嘉義縣
    var busCity: BusCity?
    var bikeCity: BikeCity?
    var metroOperator: MetroOperator?

    var availableModes: [NearbyMode] {
        var m: [NearbyMode] = []
        if busCity != nil { m.append(.bus) }
        if bikeCity != nil { m.append(.bike) }
        if metroOperator != nil { m.append(.metro) }
        // Apple's POI index has nationwide coverage, unlike TDX transit data — always
        // available regardless of which transit systems serve this area.
        m.append(.landmark)
        return m
    }
}

/// Reverse-geocodes a coordinate to a Taiwan county/city and maps it to the
/// bus / YouBike / metro systems that serve that area. No TDX call needed.
@MainActor
@Observable
final class RegionResolver {
    static let shared = RegionResolver()

    private(set) var region: LocalRegion?
    private let geocoder = CLGeocoder()
    private var lastCoord: CLLocationCoordinate2D?

    func resolve(for location: CLLocation) async {
        // Only re-geocode when moved > ~800 m.
        if let last = lastCoord {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: location)
            if moved < 800, region != nil { return }
        }
        lastCoord = location.coordinate

        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        let area = placemarks?.first?.administrativeArea
            ?? placemarks?.first?.subAdministrativeArea
            ?? ""
        region = Self.map(area: normalize(area))
    }

    /// "台北市" / "Taipei City" → "臺北市"
    private func normalize(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "台", with: "臺")
            .replacingOccurrences(of: " City", with: "")
            .replacingOccurrences(of: " County", with: "")
        if s.contains("Taipei"), !s.contains("New") { s = "臺北市" }
        return s
    }

    static func map(area: String) -> LocalRegion {
        func matches(_ displayName: String) -> Bool {
            guard !area.isEmpty else { return false }
            return area == displayName
                || area.hasPrefix(displayName)
                || displayName.hasPrefix(area)
        }
        let busCity = BusCity.allCases.first { matches($0.displayName) }
        let bikeCity = BikeCity.allCases.first { matches($0.displayName) }

        let metro: MetroOperator?
        switch area {
        case let a where a.contains("臺北") || a.contains("新北") || a.contains("基隆"):
            metro = .trtc
        case let a where a.contains("桃園"):
            metro = .tymc
        case let a where a.contains("臺中"):
            metro = .tmrt
        case let a where a.contains("高雄"):
            metro = .krtc
        default:
            metro = nil
        }

        return LocalRegion(
            areaName: area.isEmpty ? "目前位置" : area,
            busCity: busCity,
            bikeCity: bikeCity,
            metroOperator: metro
        )
    }
}
