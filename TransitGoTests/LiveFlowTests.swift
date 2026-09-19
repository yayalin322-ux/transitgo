import XCTest
import SwiftData
import CoreLocation
@testable import TransitGo

/// Real-data flow: save a favorite, "restart" (reopen the on-disk store), open it, plan it through the real
/// `UnifiedRoutingService` against a live backend, then ask the real realtime service.
/// Skipped unless a backend answers at the app's configured BackendHost (run `transitgo-server/test/local_backend.mjs`
/// — real TDX metro data, live TDX realtime — and build the tests with BACKEND_HOST=localhost:4600).
@MainActor
final class LiveFlowTests: XCTestCase {

    func testSavedFavoriteIsReopenedAfterRestartAndPlannedForRealWithRealtime() async throws {
        guard let base = BackendConfig.baseURL,
              let (_, resp) = try? await URLSession.shared.data(from: base.appendingPathComponent("v1/health")),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { throw XCTSkip("no backend reachable at BackendHost") }

        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let home = TripEndpoint(name: "家", kind: .address, latitude: 25.0143, longitude: 121.4640)          // 板橋
        var savedID: UUID!

        do {   // session 1: save
            let container = try AppStore.makeContainer(url: url)
            let trip = try TripStore(context: container.mainContext).addFavorite(name: "家 → 台北車站", spec: TripSpec(origin: home, destination: Place.taipeiMain, profile: .fastest))
            savedID = trip.id
            try container.mainContext.save()
        }

        // session 2: "restart", find it, tap it
        let container = try AppStore.makeContainer(url: url)
        let store = TripStore(context: container.mainContext)
        let trip = try XCTUnwrap(store.favorite(id: savedID), "the favorite survived the restart")
        try store.recordUse(trip)
        XCTAssertEqual(trip.useCount, 1)

        let outcome = await TripPlanner.plan(trip.spec, city: .newTaipei, metroOperator: .trtc, currentLocation: nil, now: Date())
        guard case .routes(let planned, _) = outcome else { return XCTFail("expected real routes, got \(String(describing: outcome.message))") }
        let route = try XCTUnwrap(planned.multimodalRoutes.first, "a real route from the routing engine")
        print("LIVE-FLOW route: \(route.label) \(route.durationSeconds / 60) min, transfers \(route.transfers), segments \(route.segments.map(\.modeLabel))")
        XCTAssertTrue(route.segments.contains { $0.mode == "MRT" }, "板橋 → 台北車站 rides the real 板南線")
        XCTAssertGreaterThan(route.durationSeconds, 0)

        let enriched = await TripPlanner.withRealtime(planned)
        let lookup = try XCTUnwrap(enriched.realtimeByRouteId[route.id], "the realtime service was asked")
        switch lookup {
        case .loaded(let overlay): print("LIVE-FLOW realtime: loaded, \(overlay.cardLine), eta \(overlay.eta.etaSource)")
        case .unavailable(let reason): print("LIVE-FLOW realtime: unavailable (\(reason.rawValue)) — static route still shown")
        case .notRequested: XCTFail("realtime should have been requested")
        }
        XCTAssertEqual(enriched.routes.count, planned.routes.count, "realtime never removes a route")
        XCTAssertEqual(store.favorite(id: savedID)?.spec.destination, Place.taipeiMain, "planning left the favorite untouched")
    }
}
