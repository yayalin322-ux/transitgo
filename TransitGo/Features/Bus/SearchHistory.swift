import Foundation

/// A bus route the user recently opened. Stored locally so "最近搜尋" lists real
/// routes you can tap straight back into, not raw text.
struct RecentRoute: Codable, Identifiable, Hashable {
    var scopeKey: String       // BusScope.storageKey
    var routeUID: String
    var name: String
    var endpoints: String

    var id: String { scopeKey + "/" + routeUID }
    var scope: BusScope { BusScope(storageKey: scopeKey) ?? .city(.taipei) }
}

/// Local recent-routes list for the bus tab. UserDefaults-backed, device-only.
@MainActor
@Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private let key = "bus.recentRoutes.v1"
    private let maxItems = 12
    private(set) var routes: [RecentRoute] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RecentRoute].self, from: data) {
            routes = decoded
        }
    }

    func record(scope: BusScope, route: BusRoute) {
        let item = RecentRoute(
            scopeKey: scope.storageKey,
            routeUID: route.routeUID,
            name: route.name,
            endpoints: route.endpointsText
        )
        routes.removeAll { $0.id == item.id }
        routes.insert(item, at: 0)
        if routes.count > maxItems { routes = Array(routes.prefix(maxItems)) }
        persist()
    }

    func remove(_ item: RecentRoute) {
        routes.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        routes = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
