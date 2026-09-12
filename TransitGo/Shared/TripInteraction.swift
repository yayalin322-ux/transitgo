import Foundation
import AppIntents
import ActivityKit

/// Where a tracked trip is in its board → ride → alight → rate lifecycle.
enum TripStage: String, Codable, Hashable {
    case awaitingBoard   // waiting at the stop; LA asks "你上車了嗎？"
    case riding          // confirmed on board; counting down to the alight stop
    case awaitingAlight  // at/near the alight stop; LA asks "你下車了嗎？"
    case rating          // LA shows a 1–5 star prompt
    case done            // finished; LA about to end
}

/// One-slot mailbox the Live Activity buttons use to tell the running tracker what
/// the user did. The intents run inside the app process, so plain `UserDefaults`
/// (the app's own) is enough — no App Group needed.
enum TripInteraction {
    private static let key = "trip.pendingAction"

    static func post(_ action: String) {
        UserDefaults.standard.set(action, forKey: key)
    }
    static func consume() -> String? {
        let d = UserDefaults.standard
        guard let a = d.string(forKey: key) else { return nil }
        d.removeObject(forKey: key)
        return a
    }

    // Rating history (lightweight; shown nowhere yet but kept for later).
    static func recordRating(_ stars: Int, route: String, from: String, to: String) {
        var arr = (UserDefaults.standard.array(forKey: "trip.ratings") as? [[String: Any]]) ?? []
        arr.insert(["stars": stars, "route": route, "from": from, "to": to,
                    "at": Date().timeIntervalSince1970], at: 0)
        UserDefaults.standard.set(Array(arr.prefix(50)), forKey: "trip.ratings")
    }
}

// MARK: - Live Activity buttons

/// Advances the trip one step: awaitingBoard → riding, riding/awaitingAlight → rating.
struct AdvanceTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "確認" }
    init() {}

    func perform() async throws -> some IntentResult {
        TripInteraction.post("advance")
        await Self.nudgeBus()
        await Self.nudgeRail()
        return .result()
    }

    private static func nudgeBus() async {
        for activity in Activity<BusTripAttributes>.activities {
            var s = activity.content.state
            switch s.stage {
            case .awaitingBoard: s.stage = .riding; s.onboard = true; s.hint = "記得提前按下車鈴"
            case .riding, .awaitingAlight: s.stage = .rating; s.hint = nil
            default: continue
            }
            s.updatedAt = .now
            await activity.update(ActivityContent(state: s, staleDate: Date().addingTimeInterval(300)))
        }
    }
    private static func nudgeRail() async {
        for activity in Activity<RailTripAttributes>.activities {
            var s = activity.content.state
            switch s.stage {
            case .awaitingBoard: s.stage = .riding
            case .riding, .awaitingAlight: s.stage = .rating
            default: continue
            }
            s.updatedAt = .now
            await activity.update(ActivityContent(state: s, staleDate: Date().addingTimeInterval(300)))
        }
    }
}

/// "看下一班" — stop watching the current bus, wait for the one after.
struct NextBusTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "看下一班" }
    init() {}
    func perform() async throws -> some IntentResult {
        TripInteraction.post("nextbus")
        return .result()
    }
}

/// Records a 1–5 star rating and ends the Live Activity.
struct RateTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "評分" }

    @Parameter(title: "分數") var stars: Int
    init() {}
    init(stars: Int) { self.stars = stars }

    func perform() async throws -> some IntentResult {
        TripInteraction.post("rate:\(stars)")
        for activity in Activity<BusTripAttributes>.activities {
            var s = activity.content.state
            s.rating = stars; s.stage = .done; s.statusText = "感謝評分"; s.hint = nil
            await activity.end(ActivityContent(state: s, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(8)))
        }
        for activity in Activity<RailTripAttributes>.activities {
            var s = activity.content.state
            s.rating = stars; s.stage = .done; s.phase = "感謝評分"
            await activity.end(ActivityContent(state: s, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(8)))
        }
        return .result()
    }
}
