import Foundation
import ActivityKit

/// Live Activity for "heading to a YouBike station" — live 可借 / 可還 counts as you walk.
struct BikeTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var availableRent: Int
        var availableReturn: Int
        var generalBikes: Int?
        var electricBikes: Int?
        var inService: Bool
        var updatedAt: Date
    }

    var stationName: String
    var cityName: String
    /// "借車" or "還車" — what the user is going there to do.
    var intent: String
}
