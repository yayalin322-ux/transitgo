import Foundation
import ActivityKit

/// Live Activity for a metro station — countdown to the next train in your direction.
struct MetroTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Predicted arrival of the next train (drives the countdown); nil while unknown.
        var nextArrival: Date?
        var nextEtaMinutes: Int?
        var followingEtaMinutes: Int?
        var statusText: String       // "進站中" / "3 分" / "暫停營運"
        var updatedAt: Date
    }

    var systemName: String       // 臺北捷運…
    var lineName: String         // 板南線
    var stationName: String
    var heading: String          // "往南港展覽館"
}
