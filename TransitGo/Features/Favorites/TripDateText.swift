import Foundation

/// Wording for when a journey was last used/searched. Pure functions of (date, now) so they can be tested.
enum TripDateText {
    private static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return c
    }
    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar(); f.timeZone = calendar().timeZone
        f.locale = Locale(identifier: "zh_Hant_TW"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    private static func monthDay(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar(); f.timeZone = calendar().timeZone
        f.locale = Locale(identifier: "zh_Hant_TW"); f.dateFormat = "M/d"
        return f.string(from: d)
    }

    /// "上次使用：今天 07:32" / "昨天 …" / "9/12 …" / "尚未使用". Never a duration of the trip itself.
    static func lastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "尚未使用" }
        let cal = calendar()
        if cal.isDate(date, inSameDayAs: now) { return "上次使用：今天 \(clock(date))" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "上次使用：昨天 \(clock(date))" }
        return "上次使用：\(monthDay(date)) \(clock(date))"
    }

    /// "剛剛" / "10 分鐘前" / "2 小時前" (same day) / "昨天" / "9/12".
    static func recent(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar()
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "剛剛" }
        if cal.isDate(date, inSameDayAs: now) {
            return seconds < 3600 ? "\(Int(seconds / 60)) 分鐘前" : "\(Int(seconds / 3600)) 小時前"
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "昨天" }
        return monthDay(date)
    }
}
