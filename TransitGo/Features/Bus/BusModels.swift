import Foundation
import CoreLocation

/// Cities served by the TDX **City Bus** API (`.../City/{City}`).
enum BusCity: String, CaseIterable, Identifiable {
    case taipei = "Taipei"
    case newTaipei = "NewTaipei"
    case taoyuan = "Taoyuan"
    case taichung = "Taichung"
    case tainan = "Tainan"
    case kaohsiung = "Kaohsiung"
    case keelung = "Keelung"
    case hsinchu = "Hsinchu"
    case hsinchuCounty = "HsinchuCounty"
    case miaoliCounty = "MiaoliCounty"
    case changhuaCounty = "ChanghuaCounty"
    case nantouCounty = "NantouCounty"
    case yunlinCounty = "YunlinCounty"
    case chiayi = "Chiayi"
    case chiayiCounty = "ChiayiCounty"
    case pingtungCounty = "PingtungCounty"
    case yilanCounty = "YilanCounty"
    case hualienCounty = "HualienCounty"
    case taitungCounty = "TaitungCounty"
    case penghuCounty = "PenghuCounty"
    case kinmenCounty = "KinmenCounty"
    case lienchiangCounty = "LienchiangCounty"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .taipei: return "臺北市"
        case .newTaipei: return "新北市"
        case .taoyuan: return "桃園市"
        case .taichung: return "臺中市"
        case .tainan: return "臺南市"
        case .kaohsiung: return "高雄市"
        case .keelung: return "基隆市"
        case .hsinchu: return "新竹市"
        case .hsinchuCounty: return "新竹縣"
        case .miaoliCounty: return "苗栗縣"
        case .changhuaCounty: return "彰化縣"
        case .nantouCounty: return "南投縣"
        case .yunlinCounty: return "雲林縣"
        case .chiayi: return "嘉義市"
        case .chiayiCounty: return "嘉義縣"
        case .pingtungCounty: return "屏東縣"
        case .yilanCounty: return "宜蘭縣"
        case .hualienCounty: return "花蓮縣"
        case .taitungCounty: return "臺東縣"
        case .penghuCounty: return "澎湖縣"
        case .kinmenCounty: return "金門縣"
        case .lienchiangCounty: return "連江縣"
        }
    }
}

/// What set of routes we're browsing: nationwide 公路客運 / 國道客運, or one city's buses.
enum BusScope: Identifiable, Hashable {
    case interCity
    case city(BusCity)

    /// InterCity first, then every city.
    static let all: [BusScope] = [.interCity] + BusCity.allCases.map(BusScope.city)

    /// The scopes most searches actually hit — used first so a nationwide search
    /// stays light on TDX. Full coverage is opt-in.
    static let priority: [BusScope] = [
        .interCity,
        .city(.taipei), .city(.newTaipei), .city(.taoyuan), .city(.taichung),
        .city(.tainan), .city(.kaohsiung), .city(.keelung),
        .city(.hsinchu), .city(.hsinchuCounty),
    ]

    var id: String { storageKey }

    var displayName: String {
        switch self {
        case .interCity: return "公路客運"
        case .city(let c): return c.displayName
        }
    }

    /// TDX path segment, e.g. `City/Taipei` or `InterCity`.
    var pathComponent: String {
        switch self {
        case .interCity: return "InterCity"
        case .city(let c): return "City/\(c.rawValue)"
        }
    }

    /// Live on-vehicle crowding comes from the Taipei bus dynamic-info centre's seat-event
    /// feed, which covers the 雙北 聯營公車 network.
    var hasCrowding: Bool {
        switch self {
        case .city(.taipei), .city(.newTaipei): return true
        default: return false
        }
    }

    /// Stable key for persistence (SwiftData favorites).
    var storageKey: String {
        switch self {
        case .interCity: return "InterCity"
        case .city(let c): return "City:\(c.rawValue)"
        }
    }

    init?(storageKey: String) {
        if storageKey == "InterCity" {
            self = .interCity
        } else if storageKey.hasPrefix("City:"), let c = BusCity(rawValue: String(storageKey.dropFirst(5))) {
            self = .city(c)
        } else if let c = BusCity(rawValue: storageKey) {   // backward compatibility
            self = .city(c)
        } else {
            return nil
        }
    }
}

// MARK: - Route search  (/v2/Bus/Route/{scope})

struct BusRoute: Codable, Identifiable, Hashable {
    let routeUID: String
    let routeName: LocalizedName
    let departureStopNameZh: String?
    let destinationStopNameZh: String?

    var id: String { routeUID }
    var name: String { routeName.display }

    enum CodingKeys: String, CodingKey {
        case routeUID = "RouteUID"
        case routeName = "RouteName"
        case departureStopNameZh = "DepartureStopNameZh"
        case destinationStopNameZh = "DestinationStopNameZh"
    }

    var endpointsText: String {
        let a = departureStopNameZh ?? "—"
        let b = destinationStopNameZh ?? "—"
        return "\(a) ↔ \(b)"
    }
}

// MARK: - Route info  (/v2/Bus/Route/{scope}/{RouteName}, full)

struct BusOperator: Codable, Identifiable, Hashable {
    let operatorID: String
    let operatorName: LocalizedName
    var id: String { operatorID }
    var name: String { operatorName.display }

    enum CodingKeys: String, CodingKey {
        case operatorID = "OperatorID"
        case operatorName = "OperatorName"
    }
}

struct BusRouteInfo: Codable {
    let operators: [BusOperator]?
    let routeMapImageUrl: String?
    let ticketPriceDescriptionZh: String?

    enum CodingKeys: String, CodingKey {
        case operators = "Operators"
        case routeMapImageUrl = "RouteMapImageUrl"
        case ticketPriceDescriptionZh = "TicketPriceDescriptionZh"
    }

    var operatorNames: String {
        (operators ?? []).map(\.name).joined(separator: "、")
    }
}

// MARK: - Schedule  (/v2/Bus/Schedule/{scope}/{RouteName})

struct BusScheduleEntry: Codable {
    let direction: Int
    let subRouteName: LocalizedName?
    let frequencys: [BusFrequency]?
    let timetables: [BusScheduleTimetable]?

    enum CodingKeys: String, CodingKey {
        case direction = "Direction"
        case subRouteName = "SubRouteName"
        case frequencys = "Frequencys"
        case timetables = "Timetables"
    }
}

struct BusFrequency: Codable, Identifiable {
    let startTime: String
    let endTime: String
    let minHeadwayMins: Int?
    let maxHeadwayMins: Int?
    let serviceDay: ServiceDay?

    var id: String { "\(startTime)-\(endTime)-\(serviceDay?.label ?? "")" }

    enum CodingKeys: String, CodingKey {
        case startTime = "StartTime"
        case endTime = "EndTime"
        case minHeadwayMins = "MinHeadwayMins"
        case maxHeadwayMins = "MaxHeadwayMins"
        case serviceDay = "ServiceDay"
    }

    var headwayText: String {
        switch (minHeadwayMins, maxHeadwayMins) {
        case let (min?, max?) where min == max: return "約 \(min) 分"
        case let (min?, max?): return "\(min)–\(max) 分"
        case let (min?, nil): return "約 \(min) 分"
        default: return "—"
        }
    }
}

struct BusScheduleTimetable: Codable, Identifiable {
    let arrivalTime: String?
    let departureTime: String?
    let serviceDay: ServiceDay?
    /// 公路客運 puts the trip's times inside StopTimes[] instead of at top level.
    let stopTimes: [BusScheduleStopTime]?
    var id: String { time + (serviceDay?.label ?? "") }

    enum CodingKeys: String, CodingKey {
        case arrivalTime = "ArrivalTime"
        case departureTime = "DepartureTime"
        case serviceDay = "ServiceDay"
        case stopTimes = "StopTimes"
    }

    /// Departure time from the origin stop.
    var time: String {
        departureTime
            ?? stopTimes?.first?.departureTime
            ?? stopTimes?.first?.arrivalTime
            ?? arrivalTime
            ?? "—"
    }
    var serviceDayLabel: String { serviceDay?.label ?? "" }
}

struct BusScheduleStopTime: Codable {
    let arrivalTime: String?
    let departureTime: String?
    enum CodingKeys: String, CodingKey {
        case arrivalTime = "ArrivalTime"
        case departureTime = "DepartureTime"
    }
}

struct ServiceDay: Codable {
    let sunday, monday, tuesday, wednesday, thursday, friday, saturday: Int?

    enum CodingKeys: String, CodingKey {
        case sunday = "Sunday", monday = "Monday", tuesday = "Tuesday"
        case wednesday = "Wednesday", thursday = "Thursday", friday = "Friday", saturday = "Saturday"
    }

    /// e.g. "每日"、"平日"、"假日"、"週一"
    var label: String {
        let flags = [sunday, monday, tuesday, wednesday, thursday, friday, saturday].map { ($0 ?? 0) == 1 }
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let on = zip(flags, names).filter { $0.0 }.map { $0.1 }
        if on.count == 7 { return "每日" }
        if on == ["一", "二", "三", "四", "五"] { return "平日" }
        if Set(on) == Set(["日", "六"]) { return "假日" }
        if on.isEmpty { return "" }
        return "週" + on.joined(separator: "、")
    }
}

// MARK: - Vehicle  (/v2/Bus/Vehicle/City/{City})

struct VehicleInfo: Codable {
    let plateNumb: String
    let isLowFloor: Int?
    let hasLiftOrRamp: Int?
    let isElectric: Int?

    enum CodingKeys: String, CodingKey {
        case plateNumb = "PlateNumb"
        case isLowFloor = "IsLowFloor"
        case hasLiftOrRamp = "HasLiftOrRamp"
        case isElectric = "IsElectric"
    }

    var lowFloor: Bool { (isLowFloor ?? 0) == 1 }
    var lift: Bool { (hasLiftOrRamp ?? 0) == 1 }
    var electric: Bool { (isElectric ?? 0) == 1 }
}

// MARK: - Stops of route  (/v2/Bus/StopOfRoute/{scope}/{RouteName})

struct BusStopOfRoute: Codable {
    let direction: Int
    let stops: [BusRouteStop]

    enum CodingKeys: String, CodingKey {
        case direction = "Direction"
        case stops = "Stops"
    }
}

struct BusRouteStop: Codable, Identifiable, Hashable {
    let stopUID: String
    let stopName: LocalizedName
    let stopSequence: Int
    let stopPosition: GeoPoint?

    var id: String { stopUID }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = stopPosition?.lat, let lon = stopPosition?.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case stopUID = "StopUID"
        case stopName = "StopName"
        case stopSequence = "StopSequence"
        case stopPosition = "StopPosition"
    }
}

// MARK: - Estimated time of arrival  (/v2/Bus/EstimatedTimeOfArrival/{scope}/{RouteName})

struct BusEstimate: Codable {
    let stopUID: String
    let direction: Int
    let estimateTime: Int?
    let stopStatus: Int?
    let plateNumb: String?

    enum CodingKeys: String, CodingKey {
        case stopUID = "StopUID"
        case direction = "Direction"
        case estimateTime = "EstimateTime"
        case stopStatus = "StopStatus"
        case plateNumb = "PlateNumb"
    }

    var displayText: String {
        switch stopStatus {
        case 1: return "尚未發車"
        case 2: return "交管不停靠"
        case 3: return "末班已過"
        case 4: return "今日未營運"
        default: return Fmt.eta(seconds: estimateTime)
        }
    }

    var isActionable: Bool { (stopStatus ?? 0) == 0 && estimateTime != nil }

    /// Plate of the next arriving bus, if the feed provides one (InterCity does; most city feeds don't).
    var plate: String? {
        guard let p = plateNumb, p != "-1", !p.isEmpty else { return nil }
        return p
    }
}

// MARK: - Arrivals at one stop  (/v2/Bus/EstimatedTimeOfArrival/City/{City}?$filter=StopUID eq '…')

struct StopArrival: Identifiable {
    let routeName: String
    let direction: Int
    let estimateTime: Int?
    let stopStatus: Int?

    var id: String { "\(routeName)-\(direction)" }

    var displayText: String {
        switch stopStatus {
        case 1: return "尚未發車"
        case 2: return "交管不停靠"
        case 3: return "末班已過"
        case 4: return "今日未營運"
        default: return Fmt.eta(seconds: estimateTime)
        }
    }
    var sortKey: Int { estimateTime ?? (stopStatus == 0 ? 999_998 : 999_999) }

    /// From the unified realtime model. The TDX StopStatus values (1/2/3/4) round-trip through
    /// `RealtimeState`, so the on-screen wording (`displayText`) is unchanged.
    init?(realtime r: RealtimeStatus) {
        guard let name = r.routeName, let direction = r.direction else { return nil }
        self.routeName = name
        self.direction = direction
        self.estimateTime = r.etaSeconds
        switch r.state {
        case .notDeparted: self.stopStatus = 1
        case .notStopping: self.stopStatus = 2
        case .lastServicePassed: self.stopStatus = 3
        case .notOperating: self.stopStatus = 4
        default: self.stopStatus = r.etaSeconds == nil ? nil : 0
        }
    }
}

struct RawStopETA: Decodable {
    let routeName: LocalizedName
    let direction: Int
    let estimateTime: Int?
    let stopStatus: Int?
    enum CodingKeys: String, CodingKey {
        case routeName = "RouteName"
        case direction = "Direction"
        case estimateTime = "EstimateTime"
        case stopStatus = "StopStatus"
    }
}

// MARK: - Route shape  (/v2/Bus/Shape/{scope}/{RouteName})

struct BusShapeEntry: Decodable {
    let direction: Int?
    let geometry: String?
    enum CodingKeys: String, CodingKey {
        case direction = "Direction"
        case geometry = "Geometry"
    }
}

// MARK: - Live positions  (/v2/Bus/RealTimeByFrequency/{scope}/{RouteName})

struct BusRealTimeFreq: Decodable {
    let plateNumb: String
    let direction: Int
    let busPosition: BusPos?
    let azimuth: Double?
    enum CodingKeys: String, CodingKey {
        case plateNumb = "PlateNumb"
        case direction = "Direction"
        case busPosition = "BusPosition"
        case azimuth = "Azimuth"
    }
}

struct BusPos: Decodable {
    let positionLat: Double?
    let positionLon: Double?
    enum CodingKeys: String, CodingKey {
        case positionLat = "PositionLat"
        case positionLon = "PositionLon"
    }
}

// MARK: - Buses near a stop  (/v2/Bus/RealTimeNearStop/{scope}/{RouteName})

struct BusRealTimeNearStop: Codable {
    let plateNumb: String
    let direction: Int
    let stopUID: String
    let stopSequence: Int
    let a2EventType: Int?   // 0 = 離站, 1 = 到站

    enum CodingKeys: String, CodingKey {
        case plateNumb = "PlateNumb"
        case direction = "Direction"
        case stopUID = "StopUID"
        case stopSequence = "StopSequence"
        case a2EventType = "A2EventType"
    }
}
