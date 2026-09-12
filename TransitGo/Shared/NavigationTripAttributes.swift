import Foundation
import ActivityKit

/// Live Activity for an active in-app navigation session (see InAppNavigationView).
///
/// `modeLabel`/`modeSymbol` live in `ContentState`, not the fixed `ActivityAttributes`,
/// because a multi-leg trip (e.g. walk → YouBike → walk) changes transport mode mid-trip
/// without ever ending the activity — only content state can update after `Activity.request`.
struct NavigationTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var distanceMeters: Int
        var etaMinutes: Int
        var offRoute: Bool
        var arrived: Bool
        /// Display text for the current leg's mode, e.g. "開車" / "走路" / "騎腳踏車".
        var modeLabel: String
        var modeSymbol: String
        /// "2/3" style progress for a multi-leg trip; nil for a single-leg one (hidden in the UI).
        var legProgress: String?
    }

    /// The trip's overall/final destination — fixed for the whole Live Activity even as
    /// intermediate legs (and their own destinations) come and go.
    var destinationName: String
}
