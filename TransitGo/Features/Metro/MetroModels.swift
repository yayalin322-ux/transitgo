import Foundation
import CoreLocation
import SwiftUI

enum MetroOperator: String, CaseIterable, Identifiable {
    case trtc = "TRTC"
    case krtc = "KRTC"
    case tymc = "TYMC"
    case tmrt = "TMRT"
    case ntdlrt = "NTDLRT"
    case krtcLRT = "KLRT"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .trtc: return "臺北捷運"
        case .krtc: return "高雄捷運"
        case .tymc: return "桃園機捷"
        case .tmrt: return "臺中捷運"
        case .ntdlrt: return "淡海輕軌"
        case .krtcLRT: return "高雄輕軌"
        }
    }
    /// TDX only publishes real-time LiveBoard for some operators.
    var hasLiveBoard: Bool {
        switch self {
        case .trtc, .krtc, .tymc, .tmrt: return true
        default: return false
        }
    }
}

struct MetroLine: Codable, Identifiable, Hashable {
    let lineID: String
    let lineName: LocalizedName
    let lineColor: String?
    var id: String { lineID }
    var name: String { lineName.display }
    var color: Color {
        guard let hex = lineColor else { return .indigo }
        return Color(hex: hex) ?? .indigo
    }

    enum CodingKeys: String, CodingKey {
        case lineID = "LineID"
        case lineName = "LineName"
        case lineColor = "LineColor"
    }
}

extension Color {
    /// Parses a "#rrggbb" (or "rrggbb") hex string, as TDX's `LineColor` field uses.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

struct MetroStationOfLine: Codable {
    let lineID: String
    let stations: [MetroLineStation]
    enum CodingKeys: String, CodingKey {
        case lineID = "LineID"
        case stations = "Stations"
    }
}

struct MetroLineStation: Codable, Identifiable, Hashable {
    let sequence: Int
    let stationID: String
    let stationName: LocalizedName
    var id: String { stationID }
    var name: String { stationName.display }

    enum CodingKeys: String, CodingKey {
        case sequence = "Sequence"
        case stationID = "StationID"
        case stationName = "StationName"
    }
}

struct MetroStation: Codable, Identifiable, Hashable {
    let stationUID: String
    let stationID: String
    let stationName: LocalizedName
    let stationPosition: GeoPoint?

    var id: String { stationID }
    var name: String { stationName.display }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = stationPosition?.lat, let lon = stationPosition?.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case stationUID = "StationUID"
        case stationID = "StationID"
        case stationName = "StationName"
        case stationPosition = "StationPosition"
    }
}

/// One row of `/v2/Rail/Metro/LiveBoard/{Operator}`.
struct MetroLiveBoard: Codable, Identifiable {
    let lineID: String
    let lineName: LocalizedName
    let stationID: String
    let stationName: LocalizedName
    let tripHeadSign: String?
    let destinationStationName: LocalizedName?
    let serviceStatus: Int?
    let estimateTime: Int?     // minutes

    var id: String { "\(lineID)-\(stationID)-\(destinationStationName?.display ?? tripHeadSign ?? "")" }

    enum CodingKeys: String, CodingKey {
        case lineID = "LineID"
        case lineName = "LineName"
        case stationID = "StationID"
        case stationName = "StationName"
        case tripHeadSign = "TripHeadSign"
        case destinationStationName = "DestinationStationName"
        case serviceStatus = "ServiceStatus"
        case estimateTime = "EstimateTime"
    }

    var headingText: String {
        tripHeadSign ?? destinationStationName.map { "往 \($0.display)" } ?? "—"
    }
    var etaText: String {
        guard let t = estimateTime else { return "—" }
        if t <= 0 { return "進站中" }
        return "\(t) 分"
    }
}

struct MetroStationLive: Identifiable {
    let station: MetroStation
    var distance: CLLocationDistance = .greatestFiniteMagnitude
    var next: [MetroLiveBoard] = []
    var id: String { station.stationID }
}

// MARK: - Alert (v2/Rail/Metro/Alert/{Operator})

struct MetroAlertResponse: Codable {
    let alerts: [MetroAlertItem]
    enum CodingKeys: String, CodingKey { case alerts = "Alerts" }
}

struct MetroAlertItem: Codable, Identifiable, Hashable {
    let alertID: String
    let title: String
    let description: String?
    let status: Int?
    var id: String { alertID }
    /// TDX's baseline "everything's fine" row — filter these out of anything shown as a warning.
    var isNormal: Bool { title.contains("正常營運") }

    enum CodingKeys: String, CodingKey {
        case alertID = "AlertID"
        case title = "Title"
        case description = "Description"
        case status = "Status"
    }
}

// MARK: - First/last train (v2/Rail/Metro/FirstLastTimetable/{Operator})

struct MetroFirstLastTrip: Codable, Identifiable, Hashable {
    let lineID: String
    let stationID: String
    let tripHeadSign: String?
    let destinationStationName: LocalizedName?
    let firstTrainTime: String
    let lastTrainTime: String

    var id: String { "\(lineID)-\(stationID)-\(tripHeadSign ?? "")" }
    var headingText: String {
        tripHeadSign ?? destinationStationName.map { "往 \($0.display)" } ?? "—"
    }

    enum CodingKeys: String, CodingKey {
        case lineID = "LineID"
        case stationID = "StationID"
        case tripHeadSign = "TripHeadSign"
        case destinationStationName = "DestinationStationName"
        case firstTrainTime = "FirstTrainTime"
        case lastTrainTime = "LastTrainTime"
    }
}

// MARK: - OD fare (v2/Rail/Metro/ODFare/{Operator})

struct MetroODFareRow: Codable {
    let originStationID: String
    let destinationStationID: String
    let fares: [MetroFareEntry]

    enum CodingKeys: String, CodingKey {
        case originStationID = "OriginStationID"
        case destinationStationID = "DestinationStationID"
        case fares = "Fares"
    }
}

struct MetroFareEntry: Codable, Hashable {
    let ticketType: Int
    let fareClass: Int
    let citizenCode: String?
    let price: Int

    enum CodingKeys: String, CodingKey {
        case ticketType = "TicketType"
        case fareClass = "FareClass"
        case citizenCode = "CitizenCode"
        case price = "Price"
    }
}

// MARK: - Station-to-station travel time (v2/Rail/Metro/S2STravelTime/{Operator})

struct MetroS2SRoute: Codable {
    let lineID: String
    let travelTimes: [MetroS2SSegment]
    enum CodingKeys: String, CodingKey {
        case lineID = "LineID"
        case travelTimes = "TravelTimes"
    }
}

struct MetroS2SSegment: Codable {
    let sequence: Int
    let fromStationID: String
    let toStationID: String
    let runTime: Int      // seconds
    let stopTime: Int     // seconds, dwell time added at the destination stop

    enum CodingKeys: String, CodingKey {
        case sequence = "Sequence"
        case fromStationID = "FromStationID"
        case toStationID = "ToStationID"
        case runTime = "RunTime"
        case stopTime = "StopTime"
    }
}
