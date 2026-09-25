import Foundation

/// One departure on a station's board (from the backend's /v1/rail/board — see transitgo-server/src/realtime/railBoard.mjs).
struct RailBoardTrain: Decodable, Identifiable, Equatable {
    let trainNo: String
    let type: String
    let dest: String
    let depart: String          // "HH:mm", the timetable time
    let delayMinutes: Int?
    let platform: String?
    let heading: String         // north | south | other | unknown

    var id: String { trainNo + depart }

    /// Minutes from `now` until it leaves, delay included (negative = already gone). Wraps at midnight.
    func minutesUntil(_ now: Date, calendar: Calendar = RailBoard.taipei) -> Int {
        let nowMin = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let parts = depart.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return .min }
        var ahead = parts[0] * 60 + parts[1] + (delayMinutes ?? 0) - nowMin
        if ahead < -720 { ahead += 1440 }
        if ahead > 720 { ahead -= 1440 }
        return ahead
    }

    /// "自強 → 新左營"
    var summary: String { type.isEmpty ? "→ \(dest)" : "\(type) → \(dest)" }
    var delayText: String? {
        guard let d = delayMinutes else { return nil }
        return d > 0 ? "誤點 \(d) 分" : "準點"
    }
}

/// A station's board, split into the two directions people ask about.
struct RailBoard: Decodable, Equatable {
    struct Station: Decodable, Equatable { let id: String; let name: String? }

    let ok: Bool?
    let available: Bool
    let reason: String?
    let stale: Bool?
    let fetchedAt: Double?
    let station: Station
    let northbound: [RailBoardTrain]
    let southbound: [RailBoardTrain]
    let other: [RailBoardTrain]
    let headingsKnown: Bool

    enum CodingKeys: String, CodingKey { case ok, available, reason, stale, fetchedAt, station, northbound, southbound, other, headingsKnown }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        fetchedAt = try c.decodeIfPresent(Double.self, forKey: .fetchedAt)
        station = try c.decode(Station.self, forKey: .station)
        // An "unavailable" answer carries no lists — say so with empty ones, never with invented trains.
        northbound = try c.decodeIfPresent([RailBoardTrain].self, forKey: .northbound) ?? []
        southbound = try c.decodeIfPresent([RailBoardTrain].self, forKey: .southbound) ?? []
        other = try c.decodeIfPresent([RailBoardTrain].self, forKey: .other) ?? []
        headingsKnown = try c.decodeIfPresent(Bool.self, forKey: .headingsKnown) ?? false
    }

    static var taipei: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return c
    }

    var stationName: String { station.name ?? station.id }

    /// Trains still to come at `now` (a train that left more than `grace` minutes ago is dropped), soonest first.
    static func upcoming(_ trains: [RailBoardTrain], at now: Date, grace: Int = 1) -> [RailBoardTrain] {
        trains.filter { $0.minutesUntil(now) >= -grace }.sorted { $0.minutesUntil(now) < $1.minutesUntil(now) }
    }

    func north(at now: Date) -> [RailBoardTrain] { Self.upcoming(northbound, at: now) }
    func south(at now: Date) -> [RailBoardTrain] { Self.upcoming(southbound, at: now) }
    func rest(at now: Date) -> [RailBoardTrain] { Self.upcoming(other, at: now) }

    /// What Siri says for "下一班北上／南下".
    func spoken(heading: RailHeading, at now: Date) -> String {
        guard available else { return "現在查不到\(stationName)站的列車資料，請稍後再試。" }
        let name = stationName + "站"
        let trains = heading == .north ? north(at: now) : south(at: now)
        guard let t = trains.first else {
            return headingsKnown ? "\(name)目前沒有\(heading.label)的班次。" : "\(name)目前查不到\(heading.label)的班次。"
        }
        let mins = max(0, t.minutesUntil(now))
        let when = mins == 0 ? "馬上進站" : "\(mins) 分鐘後"
        var s = "\(name)下一班\(heading.label)是\(t.depart)開往\(t.dest)的\(t.type.isEmpty ? "列車" : t.type)，\(when)。"
        if let d = t.delayMinutes, d > 0 { s += "目前誤點\(d)分鐘。" }
        if stale == true { s += "（資料可能不是最新）" }
        return s
    }
}

enum RailHeading: String {
    case north, south
    var label: String { self == .north ? "北上" : "南下" }
}

/// One TRA station for pickers (widget configuration, Siri).
struct RailStationInfo: Decodable, Equatable {
    let id: String
    let name: String
}

enum RailBoardService {
    enum Failure: Error { case notConfigured, badResponse }

    static func board(stationID: String) async throws -> RailBoard {
        guard let base = BackendConfig.baseURL else { throw Failure.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent("v1/rail/board"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "station", value: stationID)]
        guard let url = comps?.url else { throw Failure.badResponse }
        return try JSONDecoder().decode(RailBoard.self, from: try await get(url))
    }

    static func stations() async throws -> [RailStationInfo] {
        guard let base = BackendConfig.baseURL else { throw Failure.notConfigured }
        struct Response: Decodable { let available: Bool; let stations: [RailStationInfo] }
        let r = try JSONDecoder().decode(Response.self, from: try await get(base.appendingPathComponent("v1/rail/stations")))
        guard r.available else { throw Failure.badResponse }
        return r.stations
    }

    /// Same cold-start-tolerant pattern as the other backend calls: a quick try, then one longer retry.
    private static func get(_ url: URL) async throws -> Data {
        func once(_ timeout: TimeInterval) async throws -> Data {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
            return data
        }
        if let d = try? await once(8) { return d }
        return try await once(20)
    }
}
