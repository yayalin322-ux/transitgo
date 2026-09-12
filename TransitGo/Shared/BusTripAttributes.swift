import Foundation
import ActivityKit

/// Live Activity for "tracking a bus ride" — waiting to board at one stop, then
/// riding to an alight stop. Shown on the Lock Screen and in the Dynamic Island.
struct BusTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Predicted arrival at the currently-relevant stop. Drives the live countdown.
        var etaDate: Date?
        /// Stops remaining before the currently-relevant stop (nil if unknown).
        var stopsAway: Int?
        /// Short status line, e.g. "3 站後到站"、"即將進站".
        var statusText: String
        /// Vehicle plate, when known.
        var plate: String?
        /// `CrowdLevel` raw value (0/1/2), when known.
        var crowdingRaw: Int?
        /// Last time the app refreshed this activity.
        var updatedAt: Date
        /// Contextual prompt, e.g. "看到車記得舉手招車" / "記得提前按下車鈴". nil = none.
        var hint: String?
        /// false = still waiting to board (target = 上車站); true = on the bus (target = 下車站).
        var onboard: Bool = false
        /// Where the trip is in the board → ride → alight → rate flow.
        var stage: TripStage = .riding
        /// 1–5 stars once the user rates the trip.
        var rating: Int?

        var crowdingLabel: String? {
            switch crowdingRaw {
            case 0: return "舒適"
            case 1: return "普通"
            case 2: return "擁擠"
            default: return nil
            }
        }

        /// True right at the moment that matters — about to reach the currently-relevant
        /// stop — so the Live Activity can visually swell instead of staying the same
        /// size the whole ride.
        var isArriving: Bool {
            if let n = stopsAway, n <= 0 { return true }
            if let eta = etaDate { return eta.timeIntervalSinceNow < 60 }
            return false
        }
    }

    /// Route number, e.g. "307" or "1819".
    var routeName: String
    /// Human scope, e.g. "公路客運" or "臺北市".
    var scopeName: String
    /// Stop you board at.
    var boardStopName: String
    /// Stop you get off at.
    var alightStopName: String
    /// Where this ride is headed.
    var destinationName: String
    /// Seat, user-entered (e.g. "12車 5A"). Optional.
    var seat: String?

    /// Back-compat alias used by older widget code paths.
    var targetStopName: String { alightStopName }
}
