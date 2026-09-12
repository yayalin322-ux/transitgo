import Foundation

enum RailSystem: String, CaseIterable, Identifiable {
    case tra = "TRA"
    case thsr = "THSR"
    var id: String { rawValue }
    var displayName: String { self == .tra ? "台鐵" : "高鐵" }
}

struct RailStation: Identifiable, Hashable {
    let id: String       // StationID
    let name: String
}

/// Unified train result row for both TRA and THSR.
struct TrainRun: Identifiable {
    let trainNo: String
    let trainType: String     // e.g. 自強、區間、"" for THSR
    let departure: String     // "HH:mm"
    let arrival: String       // "HH:mm"
    let note: String?

    var id: String { trainNo }
    var durationText: String { Fmt.duration(from: departure, to: arrival) }
}

// MARK: - TRA v3 DTOs

struct TRAStationResponse: Decodable {
    let stations: [TRAStation]
    enum CodingKeys: String, CodingKey { case stations = "Stations" }
}

struct TRAStation: Decodable {
    let stationID: String
    let stationName: LocalizedName
    enum CodingKeys: String, CodingKey {
        case stationID = "StationID"
        case stationName = "StationName"
    }
}

struct TRATimetableResponse: Decodable {
    let trainTimetables: [TRATrainTimetable]
    enum CodingKeys: String, CodingKey { case trainTimetables = "TrainTimetables" }
}

struct TRATrainTimetable: Decodable {
    let trainInfo: TRATrainInfo
    let stopTimes: [TRAStopTime]
    enum CodingKeys: String, CodingKey {
        case trainInfo = "TrainInfo"
        case stopTimes = "StopTimes"
    }
}

struct TRATrainInfo: Decodable {
    let trainNo: String
    let trainTypeName: LocalizedName
    let note: String?
    let tripLine: Int?
    let wheelChairFlag: Int?
    let packageServiceFlag: Int?
    let diningFlag: Int?
    let breastFeedFlag: Int?
    let bikeFlag: Int?
    enum CodingKeys: String, CodingKey {
        case trainNo = "TrainNo"
        case trainTypeName = "TrainTypeName"
        case note = "Note"
        case tripLine = "TripLine"
        case wheelChairFlag = "WheelChairFlag"
        case packageServiceFlag = "PackageServiceFlag"
        case diningFlag = "DiningFlag"
        case breastFeedFlag = "BreastFeedFlag"
        case bikeFlag = "BikeFlag"
    }
}

struct TRAStopTime: Decodable {
    let stationID: String
    let stationName: LocalizedName?
    let arrivalTime: String?
    let departureTime: String?
    enum CodingKeys: String, CodingKey {
        case stationID = "StationID"
        case stationName = "StationName"
        case arrivalTime = "ArrivalTime"
        case departureTime = "DepartureTime"
    }
}

// MARK: - THSR v2 DTOs

struct THSRStation: Decodable {
    let stationID: String
    let stationName: LocalizedName
    enum CodingKeys: String, CodingKey {
        case stationID = "StationID"
        case stationName = "StationName"
    }
}

struct THSRODTimetable: Decodable {
    let dailyTrainInfo: THSRTrainInfo
    let originStopTime: THSRStopTime
    let destinationStopTime: THSRStopTime
    enum CodingKeys: String, CodingKey {
        case dailyTrainInfo = "DailyTrainInfo"
        case originStopTime = "OriginStopTime"
        case destinationStopTime = "DestinationStopTime"
    }
}

struct THSRTrainInfo: Decodable {
    let trainNo: String
    enum CodingKeys: String, CodingKey { case trainNo = "TrainNo" }
}

struct THSRStopTime: Decodable {
    let departureTime: String?
    let arrivalTime: String?
    enum CodingKeys: String, CodingKey {
        case departureTime = "DepartureTime"
        case arrivalTime = "ArrivalTime"
    }
}

// MARK: - TRA live board (v3, 誤點)

struct TRALiveBoardResponse: Decodable {
    let trainLiveBoards: [TRALiveBoard]
    enum CodingKeys: String, CodingKey { case trainLiveBoards = "TrainLiveBoards" }
}

struct TRALiveBoard: Decodable {
    let trainNo: String
    let stationName: LocalizedName
    let trainStationStatus: Int?   // 0 將到站, 1 進站, 2 離站
    let delayTime: Int?            // minutes

    enum CodingKeys: String, CodingKey {
        case trainNo = "TrainNo"
        case stationName = "StationName"
        case trainStationStatus = "TrainStationStatus"
        case delayTime = "DelayTime"
    }
}

// MARK: - TRA station live board (per-station, has Platform)

struct TRAStationLiveBoardResponse: Decodable {
    let stationLiveBoards: [TRAStationLiveBoard]
    enum CodingKeys: String, CodingKey { case stationLiveBoards = "StationLiveBoards" }
}

struct TRAStationLiveBoard: Decodable {
    let trainNo: String
    let platform: String?
    enum CodingKeys: String, CodingKey {
        case trainNo = "TrainNo"
        case platform = "Platform"
    }
}

// MARK: - Single train detail (all stops)

struct RailTrainStop: Identifiable, Hashable {
    let sequence: Int
    let stationID: String
    let stationName: String
    let arrival: String?
    let departure: String?
    var id: Int { sequence }
    var timeText: String {
        switch (arrival, departure) {
        case let (a?, d?) where a != d: return "\(a) / \(d)"
        case let (_, d?): return d
        case let (a?, _): return a
        default: return "—"
        }
    }
}

struct RailTrainDetail {
    let trainNo: String
    let trainType: String
    let stops: [RailTrainStop]
    var tripLine: Int? = nil          // 0 不經山海線 / 1 山線 / 2 海線
    var note: String? = nil
    var hasWheelChair = false
    var hasBike = false
    var hasDining = false
    var hasBreastFeed = false
    var hasPackageService = false

    var origin: String { stops.first?.stationName ?? "" }
    var destination: String { stops.last?.stationName ?? "" }

    var tripLineText: String? {
        switch tripLine {
        case 1: return "山線"
        case 2: return "海線"
        default: return nil
        }
    }
    /// Amenity chips: (SF Symbol, label).
    var amenities: [(String, String)] {
        var out: [(String, String)] = []
        if hasWheelChair { out.append(("figure.roll", "無障礙")) }
        if hasBike { out.append(("bicycle", "可載自行車")) }
        if hasDining { out.append(("fork.knife", "餐飲服務")) }
        if hasBreastFeed { out.append(("figure.and.child.holdinghands", "哺（集）乳室")) }
        if hasPackageService { out.append(("shippingbox", "行李託運")) }
        return out
    }

    func departure(atStationID id: String) -> String? {
        stops.first { $0.stationID == id }?.departure
    }
    func arrival(atStationID id: String) -> String? {
        stops.first { $0.stationID == id }?.arrival
    }
}

// THSR /v2/Rail/THSR/DailyTimetable/Today/TrainNo/{no}
struct THSRDailyTrain: Decodable {
    let dailyTrainInfo: THSRTrainInfo
    let stopTimes: [THSRDailyStopTime]
    enum CodingKeys: String, CodingKey {
        case dailyTrainInfo = "DailyTrainInfo"
        case stopTimes = "StopTimes"
    }
}

struct THSRDailyStopTime: Decodable {
    let stopSequence: Int?
    let stationID: String
    let stationName: LocalizedName
    let arrivalTime: String?
    let departureTime: String?
    enum CodingKeys: String, CodingKey {
        case stopSequence = "StopSequence"
        case stationID = "StationID"
        case stationName = "StationName"
        case arrivalTime = "ArrivalTime"
        case departureTime = "DepartureTime"
    }
}

// MARK: - THSR seat status  (/v2/Rail/THSR/AvailableSeatStatusList/{StationID})

struct THSRSeatStatusResponse: Decodable {
    let availableSeats: [THSRSeatTrain]
    enum CodingKeys: String, CodingKey { case availableSeats = "AvailableSeats" }
}

struct THSRSeatTrain: Decodable, Identifiable {
    let trainNo: String
    let departureTime: String?
    let endingStationName: LocalizedName?
    let stopStations: [THSRSeatStop]
    var id: String { trainNo }
    enum CodingKeys: String, CodingKey {
        case trainNo = "TrainNo"
        case departureTime = "DepartureTime"
        case endingStationName = "EndingStationName"
        case stopStations = "StopStations"
    }
}

struct THSRSeatStop: Decodable, Identifiable {
    let stationName: LocalizedName
    let standardSeatStatus: String?
    let businessSeatStatus: String?
    var id: String { stationName.display }
    enum CodingKeys: String, CodingKey {
        case stationName = "StationName"
        case standardSeatStatus = "StandardSeatStatus"
        case businessSeatStatus = "BusinessSeatStatus"
    }
}

enum SeatStatus {
    case available, limited, full, unknown
    init(_ raw: String?) {
        switch raw?.uppercased() {
        case "O": self = .available
        case "L": self = .limited
        case "X": self = .full
        default: self = .unknown
        }
    }
    var label: String {
        switch self {
        case .available: return "有位"
        case .limited: return "有限"
        case .full: return "已滿"
        case .unknown: return "—"
        }
    }
}

struct TrainLiveStatus {
    let delayMinutes: Int
    let stationName: String
    let status: Int?

    var statusText: String {
        switch status {
        case 0: return "即將到站 \(stationName)"
        case 1: return "停靠 \(stationName)"
        case 2: return "已離開 \(stationName)"
        default: return stationName.isEmpty ? "行駛中" : stationName
        }
    }
}
