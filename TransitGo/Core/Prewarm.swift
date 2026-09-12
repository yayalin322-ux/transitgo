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

    /// Render's free tier sleeps the backend after ~15 min idle and takes 30-50s to wake
    /// back up — far longer than any request timeout we can afford to block a UI on. Fire
    /// this the moment a flow that will *later* need the backend starts (e.g. beginning a
    /// transfer search), so by the time the user actually reaches a backend-dependent step
    /// (like the YouBike picker) seconds later, it's had a head start waking up. Fire-and-
    /// forget, generous timeout, failures ignored — this is purely a warm-up, never the
    /// real request.
    static func wakeBackend() {
        guard let base = BackendConfig.baseURL else { return }
        Task.detached(priority: .utility) {
            let request = URLRequest(url: base.appendingPathComponent("v1/health"), timeoutInterval: 40)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
