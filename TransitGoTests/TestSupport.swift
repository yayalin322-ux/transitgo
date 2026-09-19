import Foundation
import SwiftData
import CoreLocation
@testable import TransitGo

/// Real places used across the favorite-trip tests (coordinates of real stations/POIs in Taiwan).
enum Place {
    static let home = TripEndpoint(name: "家", kind: .address, latitude: 25.0330, longitude: 121.5436)          // 大安
    static let school = TripEndpoint(name: "學校", kind: .poi, latitude: 25.0174, longitude: 121.5397)          // 台大附近
    static let taipeiMain = TripEndpoint(name: "台北車站", kind: .mrtStation, refId: "BL12", latitude: 25.0478, longitude: 121.5170)
    static let hsinchuHSR = TripEndpoint(name: "新竹高鐵站", kind: .hsrStation, refId: "1030", latitude: 24.8081, longitude: 121.0407)
    static let taipei101 = TripEndpoint(name: "台北101", kind: .poi, latitude: 25.0339, longitude: 121.5645)
}

/// Containers must outlive the models/contexts made from them (a released container crashes SwiftData),
/// so the helper keeps every one alive for the whole test run.
@MainActor private var liveContainers: [ModelContainer] = []

@MainActor
func makeStore(inMemory: Bool = true) throws -> (TripStore, ModelContainer) {
    let container = try AppStore.makeContainer(inMemory: inMemory)
    liveContainers.append(container)
    return (TripStore(context: container.mainContext), container)
}

func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("transitgo-test-\(UUID().uuidString).store")
}

/// A MultimodalRoute decoded from JSON, exactly the way the app receives one from the backend.
func makeRoute(id: String, label: String, duration: Int = 1800) throws -> MultimodalRoute {
    let json = """
    {"routeId":"\(id)","label":"\(label)","durationSeconds":\(duration),
     "departureTime":"2026-09-21T09:00:00+08:00","arrivalTime":"2026-09-21T09:30:00+08:00",
     "walkingSeconds":300,"waitingSeconds":120,"transitSeconds":1380,"transfers":1,"fare":null,
     "walkingDistanceMeters":620,"realtimeStatus":null,"legs":[],
     "segments":[{"mode":"WALK","routeId":null,"routeShortName":null,"scopePath":null,"from":null,"to":null,"tripId":null,
       "fromName":"起點","toName":"台北車站","fromLat":25.03,"fromLng":121.54,"toLat":25.04,"toLng":121.51,
       "departureTime":"2026-09-21T09:00:00+08:00","arrivalTime":"2026-09-21T09:05:00+08:00",
       "durationSeconds":300,"stopsPassed":1,"isEstimated":true,"line":null,"towards":null,"stops":null,"walkKind":null}]}
    """
    return try JSONDecoder().decode(MultimodalRoute.self, from: Data(json.utf8))
}

func makeRouteResult(multimodalRouteId: String?, summary: String) -> RouteResult {
    RouteResult(summary: summary, legs: [], transportModes: [], departure: nil, arrival: nil, durationSeconds: 1800, transfers: 1,
                waitingSeconds: nil, walkingDistanceMeters: nil, fare: nil, realtimeStatus: nil, source: .multimodalEngine,
                multimodalRouteId: multimodalRouteId)
}

func makeResult(routes: [MultimodalRoute]) -> UnifiedRoutingService.Result {
    var r = UnifiedRoutingService.Result()
    r.multimodalRoutes = routes
    r.multimodalStatus = .success(routes)
    r.routes = routes.map { makeRouteResult(multimodalRouteId: $0.id, summary: $0.label) }
    return r
}
