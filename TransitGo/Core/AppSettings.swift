import Foundation

/// Lightweight app-wide preferences backed by `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let crowdingDemo = "crowdingDemoMode"
    }

    /// Taipei's on-vehicle crowding open-data feed is a trial feed that has stopped
    /// updating. When this is on, the app synthesises a plausible crowding level per
    /// vehicle so the plate + crowding UI is visible; badges are marked 示範.
    var crowdingDemoMode: Bool {
        didSet { defaults.set(crowdingDemoMode, forKey: Key.crowdingDemo) }
    }

    private init() {
        crowdingDemoMode = defaults.bool(forKey: Key.crowdingDemo)
    }
}
