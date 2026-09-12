import Foundation

enum Fmt {
    /// yyyy-MM-dd in Asia/Taipei, stable for API paths.
    static let apiDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parses "2025-12-12T17:23:50" (no zone) as Asia/Taipei local time.
    static let naiveDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Parses "2026/09/08 20:43:18" (no zone) as Asia/Taipei local time.
    static let slashDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    /// Parses "2026-09-08 20:41:58" (space separator, no zone) as Asia/Taipei local time.
    static let spaceDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Estimated arrival seconds -> human text.
    static func eta(seconds: Int?) -> String {
        guard let s = seconds else { return "—" }
        if s < 30 { return "進站中" }
        let m = Int((Double(s) / 60.0).rounded())
        if m < 1 { return "將到站" }
        return "\(m) 分"
    }

    /// "HH:mm" + "HH:mm" -> "1 小時 23 分"
    static func duration(from dep: String, to arr: String) -> String {
        let parts = [dep, arr].map { $0.split(separator: ":").compactMap { Int($0) } }
        guard parts[0].count == 2, parts[1].count == 2 else { return "" }
        var mins = (parts[1][0] * 60 + parts[1][1]) - (parts[0][0] * 60 + parts[0][1])
        if mins < 0 { mins += 24 * 60 }
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) 分" }
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
    }
}
