import Foundation

/// Learns the user's actual walking pace from real navigation sessions (see
/// `InAppNavigationView`) and uses it to make later walking-time estimates more accurate
/// than a generic assumption — someone who walks briskly gets shorter ETAs, someone who
/// walks slowly gets longer ones, instead of everyone getting the same flat pace.
enum WalkingSpeedLearner {
    private static let key = "nav.personalWalkingSpeedMPS"
    /// ~4.5 km/h — a reasonable general-population default until we've learned this
    /// person's actual pace from a real walking session.
    private static let defaultSpeed: Double = 1.25
    private static let minPlausible = 0.3   // slower than this isn't really "walking" (stopped/GPS noise)
    private static let maxPlausible = 3.0   // faster than this is jogging or a GPS glitch, not a walk pace

    static var speedMetersPerSecond: Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > minPlausible && v < maxPlausible ? v : defaultSpeed
    }

    /// Call with each valid `CLLocation.speed` sample during an active walking navigation.
    /// Exponential moving average — recent walks weigh more, but one bad reading (GPS jump,
    /// a red light stop) can't wreck the learned pace either.
    static func record(_ measuredSpeed: Double) {
        guard measuredSpeed > minPlausible, measuredSpeed < maxPlausible else { return }
        let updated = speedMetersPerSecond * 0.8 + measuredSpeed * 0.2
        UserDefaults.standard.set(updated, forKey: key)
    }

    static func estimatedMinutes(forMeters meters: Double) -> Int {
        max(1, Int((meters / speedMetersPerSecond / 60).rounded()))
    }
}
