import Foundation

// MARK: - Public models

struct RailFare: Equatable {
    var label: String     // "標準座" / "自由座" / "商務座"
    var price: Int
}

struct RailFareGroup: Equatable, Identifiable {
    var title: String     // "全票" / "兒童・敬老・愛心半票" / "早鳥"
    var rows: [RailFare]
    var id: String { title }
}

struct RailFareInfo: Equatable {
    var groups: [RailFareGroup]
    var distanceKm: Double?

    var isEmpty: Bool { groups.isEmpty && distanceKm == nil }
}

// MARK: - Service

struct RailFareService {
    static let shared = RailFareService()
    private let client = TDXClient.shared

    func fare(system: RailSystem, fromID: String, toID: String) async -> RailFareInfo? {
        do {
            switch system {
            case .tra:  return try await traFare(fromID: fromID, toID: toID)
            case .thsr: return try await thsrFare(fromID: fromID, toID: toID)
            }
        } catch {
            return nil
        }
    }

    // TRA `/v3/Rail/TRA/ODFare` mixes both loop directions and its FareClass codes are
    // unreliable, so we only surface the direct-route distance.
    private func traFare(fromID: String, toID: String) async throws -> RailFareInfo? {
        let resp: TRAODFareResponse = try await client.get("v3/Rail/TRA/ODFare/\(fromID)/to/\(toID)")
        let distance = resp.odFares.compactMap(\.travelDistance).filter { $0 > 0 }.min()
        guard let distance else { return nil }
        return RailFareInfo(groups: [], distanceKm: distance)
    }

    // THSR `/v2/Rail/THSR/ODFare/{from}/to/{to}`
    private func thsrFare(fromID: String, toID: String) async throws -> RailFareInfo? {
        let resp: [THSRODFare] = try await client.get("v2/Rail/THSR/ODFare/\(fromID)/to/\(toID)")
        guard let od = resp.first else { return nil }

        // CabinClass 1 標準座, 2 商務座, 3 自由座 — present standard → non-reserved → business.
        let order: [(Int, String)] = [(1, "標準座"), (3, "自由座"), (2, "商務座")]
        func rows(ticketType: Int, fareClass: Int) -> [RailFare] {
            order.compactMap { cabin, label in
                od.fares.first { $0.ticketType == ticketType && $0.fareClass == fareClass && $0.cabinClass == cabin }
                    .map { RailFare(label: label, price: $0.price) }
            }
        }

        var groups: [RailFareGroup] = []
        let full = rows(ticketType: 1, fareClass: 1)
        if !full.isEmpty { groups.append(.init(title: "全票", rows: full)) }
        let half = rows(ticketType: 1, fareClass: 9)
        if !half.isEmpty { groups.append(.init(title: "兒童・敬老・愛心半票", rows: half)) }
        let early = rows(ticketType: 8, fareClass: 1)
        if !early.isEmpty { groups.append(.init(title: "早鳥優惠（標準／商務）", rows: early)) }

        guard !groups.isEmpty else { return nil }
        return RailFareInfo(groups: groups, distanceKm: nil)
    }
}

// MARK: - DTOs

private struct TRAODFareResponse: Decodable {
    let odFares: [TRAODFare]
    enum CodingKeys: String, CodingKey { case odFares = "ODFares" }
}
private struct TRAODFare: Decodable {
    let travelDistance: Double?
    enum CodingKeys: String, CodingKey { case travelDistance = "TravelDistance" }
}
private struct THSRODFare: Decodable {
    let fares: [FareRow]
    enum CodingKeys: String, CodingKey { case fares = "Fares" }
}
private struct FareRow: Decodable {
    let ticketType: Int
    let fareClass: Int
    let cabinClass: Int
    let price: Int
    enum CodingKeys: String, CodingKey {
        case ticketType = "TicketType"
        case fareClass = "FareClass"
        case cabinClass = "CabinClass"
        case price = "Price"
    }
}
