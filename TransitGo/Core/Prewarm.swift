import Foundation

/// Warms up things the user will very likely need, right after launch, so the
/// first screen tap doesn't pay the cost. All best-effort — failures are ignored.
enum Prewarm {
    private static var done = false

    static func run() {
        guard !done else { return }
        done = true
        Task.detached(priority: .utility) {
            // OAuth token — every later request needs it.
            _ = try? await TDXAuth.shared.validToken()
            // Rail station list — used by the 車票 pickers and the 時刻表 widget.
            await RailStationStore.shared.loadIfNeeded()
        }
    }
}
