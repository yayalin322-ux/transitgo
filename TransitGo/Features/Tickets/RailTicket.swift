import Foundation
import SwiftData

@Model
final class RailTicket {
    var systemRaw: String
    var serviceDate: Date
    var trainNo: String
    var trainType: String
    var fromStationID: String
    var fromName: String
    var toStationID: String
    var toName: String
    var depTime: String       // "HH:mm"
    var arrTime: String
    var carNo: String
    var seatNo: String
    var note: String
    var createdAt: Date
    /// Stable key for pairing with a scheduled local reminder.
    var uuid: String = UUID().uuidString
    /// Minutes before departure to fire a reminder. 0 = off.
    var reminderLeadMinutes: Int = 30

    init(
        system: RailSystem,
        serviceDate: Date,
        trainNo: String,
        trainType: String,
        fromStationID: String,
        fromName: String,
        toStationID: String,
        toName: String,
        depTime: String,
        arrTime: String,
        carNo: String = "",
        seatNo: String = "",
        note: String = "",
        reminderLeadMinutes: Int = 30
    ) {
        self.uuid = UUID().uuidString
        self.reminderLeadMinutes = reminderLeadMinutes
        self.systemRaw = system.rawValue
        self.serviceDate = serviceDate
        self.trainNo = trainNo
        self.trainType = trainType
        self.fromStationID = fromStationID
        self.fromName = fromName
        self.toStationID = toStationID
        self.toName = toName
        self.depTime = depTime
        self.arrTime = arrTime
        self.carNo = carNo
        self.seatNo = seatNo
        self.note = note
        self.createdAt = .now
    }

    var system: RailSystem { RailSystem(rawValue: systemRaw) ?? .tra }

    var trainLabel: String {
        trainType.isEmpty ? trainNo : "\(trainType) \(trainNo)"
    }

    var seatLabel: String {
        switch (carNo.isEmpty, seatNo.isEmpty) {
        case (false, false): return "\(carNo) 車 \(seatNo)"
        case (true, false): return seatNo
        case (false, true): return "\(carNo) 車"
        default: return ""
        }
    }

    var departureDate: Date? { RailTime.combine(serviceDate, depTime) }

    var arrivalDate: Date? {
        guard let dep = departureDate, var arr = RailTime.combine(serviceDate, arrTime) else { return nil }
        if arr < dep { arr = arr.addingTimeInterval(86400) }   // crosses midnight
        return arr
    }

    var isPast: Bool {
        (arrivalDate ?? departureDate).map { $0 < Date() } ?? false
    }

    /// 0 = before departure, 1 = arrived. Fraction of the way through the journey.
    var progress: Double {
        guard let dep = departureDate, let arr = arrivalDate, arr > dep else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(dep) / arr.timeIntervalSince(dep)))
    }

    enum Phase { case upcoming, enRoute, arrived }
    var phase: Phase {
        let now = Date()
        if let dep = departureDate, now < dep { return .upcoming }
        if let arr = arrivalDate, now < arr { return .enRoute }
        return .arrived
    }

    /// Short human countdown, e.g. "3 天後發車" / "27 分後發車" / "行駛中" / "已抵達".
    var countdownText: String {
        switch phase {
        case .arrived: return "已抵達"
        case .enRoute: return "行駛中"
        case .upcoming:
            guard let dep = departureDate else { return "" }
            let secs = dep.timeIntervalSinceNow
            if secs < 3600 { return "\(max(1, Int(secs / 60))) 分後發車" }
            if secs < 86400 { return "\(Int(secs / 3600)) 小時後發車" }
            return "\(Int(secs / 86400)) 天後發車"
        }
    }
}

enum RailTime {
    static func combine(_ date: Date, _ hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
    }
}
