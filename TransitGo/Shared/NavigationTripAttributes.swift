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
        /// Non-nil only while riding a real bus/train leg from the multimodal route
        /// planner (e.g. "公車 THB5900") — the Dynamic Island shows this instead of the
        /// usual distance/ETA metrics, since those don't mean much for a passenger.
        var transitLabel: String?
        /// The real stop name to get off at, for that same ride leg.
        var transitAlightName: String?
        /// Real TDX live-position match, nearest vehicle to the user on this route right
        /// now — an inference, not a confirmed boarding scan (no such data source
        /// exists). Nil until resolved, or if TDX has no live position for this route.
        var transitPlate: String?
    }

    /// The trip's overall/final destination — fixed for the whole Live Activity even as
    /// intermediate legs (and their own destinations) come and go.
    var destinationName: String
}
