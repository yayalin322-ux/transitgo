import Foundation
import ActivityKit

/// Live Activity for a saved train ticket — 鐵道即時通 style: countdown to departure /
/// arrival, live delay, and your car + seat front-and-centre.
struct RailTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "距發車" / "行駛中" / "已抵達"
        var phase: String
        /// Departure or arrival instant (already delay-adjusted) the countdown targets.
        var targetDate: Date?
        /// Live delay in minutes (0 = 準點). TRA only.
        var delayMinutes: Int
        /// e.g. "停靠 臺中"、"即將到站 板橋"
        var currentStatus: String?
        var updatedAt: Date
        /// Delay-adjusted departure / arrival instants, for the journey progress bar.
        var adjustedDepart: Date?
        var adjustedArrive: Date?
        /// Contextual prompt, e.g. "準備上車" / "請收拾隨身物品，準備下車". nil = none.
        var hint: String?
        /// Boarding-station platform / track number, when the live board publishes it.
        var platform: String?
        /// Where the trip is in the board → ride → alight → rate flow.
        var stage: TripStage = .riding
        /// 1–5 stars once the user rates the trip.
        var rating: Int?

        var delayText: String {
            delayMinutes <= 0 ? "準點" : "誤點 \(delayMinutes) 分"
        }

        /// 0…1 fraction of the way through the journey.
        var progress: Double {
            guard let d = adjustedDepart, let a = adjustedArrive, a > d else {
                return phase == "已抵達" ? 1 : 0
            }
            return min(1, max(0, Date().timeIntervalSince(d) / a.timeIntervalSince(d)))
        }
    }

    var systemName: String     // 台鐵 / 高鐵
    var trainLabel: String     // "自強 123" / "0803"
    var fromName: String
    var toName: String
    var depTime: String        // "HH:mm"
    var arrTime: String
    var seatLabel: String      // "10 車 5A"（可空）
}
