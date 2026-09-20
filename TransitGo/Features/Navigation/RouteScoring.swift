import Foundation
import MapKit

/// Picks between the alternates MapKit returns. MapKit has no "prefer main roads" option, and its
/// fastest route happily cuts through 巷／弄 (narrow lanes) to save a minute. The only thing knowable
/// per route is the wording of its steps, so this counts steps that enter a lane and charges each one
/// a time penalty — a measured, explainable rule, not a claim about road class or traffic lights
/// (there is no signal data). A route much slower than the fastest is never chosen for this reason.
struct RouteOption {
    struct Step { let instruction: String; let meters: Double }
    let seconds: Double
    let meters: Double
    let steps: [Step]
}

enum RouteScoring {
    /// Seconds of penalty per step that goes into a 巷／弄.
    static let lanePenaltySeconds = 75.0
    /// Never take a route slower than the fastest by more than this factor…
    static let maxSlowdownFactor = 1.3
    /// …or by more than this many seconds, whichever allows less.
    static let maxExtraSeconds = 600.0

    /// "左轉進入中華路1483巷", "右轉進入某某弄" — the road being entered is a lane. Matches a number
    /// (Arabic or Chinese) followed by 巷/弄, so ordinary names that merely contain the character
    /// (e.g. "巷弄咖啡" as a destination) are not counted.
    static func isLaneStep(_ instruction: String) -> Bool {
        instruction.range(of: "([0-9０-９]+|[一二三四五六七八九十百]+)(巷|弄)", options: .regularExpression) != nil
    }

    static func laneStepCount(_ option: RouteOption) -> Int { option.steps.filter { isLaneStep($0.instruction) }.count }

    static func score(_ option: RouteOption) -> Double { option.seconds + lanePenaltySeconds * Double(laneStepCount(option)) }

    /// Index of the route to recommend, or nil for no options. Equal scores keep the faster one.
    static func bestIndex(_ options: [RouteOption]) -> Int? {
        guard let fastest = options.map(\.seconds).min() else { return nil }
        let limit = min(fastest * maxSlowdownFactor, fastest + maxExtraSeconds)
        let eligible = options.indices.filter { options[$0].seconds <= limit }
        return eligible.min { a, b in
            let (sa, sb) = (score(options[a]), score(options[b]))
            return sa != sb ? sa < sb : options[a].seconds < options[b].seconds
        }
    }
}

extension RouteScoring {
    static func option(from route: MKRoute) -> RouteOption {
        RouteOption(seconds: route.expectedTravelTime, meters: route.distance,
                    steps: route.steps.map { .init(instruction: $0.instructions, meters: $0.distance) })
    }
}
