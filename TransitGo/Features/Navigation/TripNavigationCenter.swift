import Foundation
import SwiftUI

/// The app-level owner of the live trip, so it keeps running when the planner sheet that started it is closed, and so
/// the home page can offer to resume one after a relaunch. Views talk to this; it wires the real dependencies.
@MainActor
@Observable
final class TripNavigationCenter {
    static let shared = TripNavigationCenter()

    private(set) var service: TripNavigationService?
    var isPresenting = false

    /// A trip that was in progress when the app was closed (nil if none / too old).
    var resumable: TripSession? {
        guard service?.isActive != true else { return nil }
        return TripNavigationService.recoverableSession(store: FileTripSessionStore())
    }

    /// The user tapped 開始行程 on a route. Permission is asked inside `start` — never earlier.
    func start(route: MultimodalRoute, origin: TripEndpoint, destination: TripEndpoint, profile: TripProfile, city: BusCity?, metroOperator: MetroOperator?) {
        service?.cancel()
        let s = TripNavigationService.live(city: city, metroOperator: metroOperator)
        service = s
        s.start(route: route, origin: origin, destination: destination, profile: profile)
        isPresenting = true
    }

    /// "恢復導航": the same trip, same leg — not planned again.
    func resume(city: BusCity?, metroOperator: MetroOperator?) {
        let s = TripNavigationService.live(city: city, metroOperator: metroOperator)
        guard s.recover() else { return }
        service = s
        isPresenting = true
    }

    func discardResumable() { FileTripSessionStore().clear() }
    func closeScreen() { isPresenting = false }
}
