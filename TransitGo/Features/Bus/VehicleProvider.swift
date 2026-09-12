import Foundation

/// Caches `/v2/Bus/Vehicle/City/{City}` (plate → low-floor / lift / electric).
/// Only city scopes are supported by TDX; InterCity returns nothing.
actor VehicleProvider {
    static let shared = VehicleProvider()

    private var cache: [String: [String: VehicleInfo]] = [:]   // scopeKey → (normalisedPlate → info)
    private var fetchedAt: [String: Date] = [:]
    private let ttl: TimeInterval = 1800

    func vehicles(scope: BusScope) async -> [String: VehicleInfo] {
        guard case .city(let city) = scope else { return [:] }
        let key = scope.storageKey

        if let cached = cache[key], let at = fetchedAt[key], Date().timeIntervalSince(at) < ttl {
            return cached
        }
        do {
            let list: [VehicleInfo] = try await TDXClient.shared.get(
                "v2/Bus/Vehicle/City/\(city.rawValue)"
            )
            let map = Dictionary(
                list.map { (normalizedPlate($0.plateNumb), $0) },
                uniquingKeysWith: { _, b in b }
            )
            cache[key] = map
            fetchedAt[key] = Date()
            return map
        } catch {
            return cache[key] ?? [:]
        }
    }
}
