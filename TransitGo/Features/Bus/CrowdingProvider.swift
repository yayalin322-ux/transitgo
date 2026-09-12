import Foundation

enum CrowdLevel: Int, CaseIterable {
    case comfortable = 0   // 座位充足
    case moderate = 1      // 尚有站位
    case crowded = 2       // 車廂擁擠

    var label: String {
        switch self {
        case .comfortable: return "舒適"
        case .moderate: return "普通"
        case .crowded: return "擁擠"
        }
    }
}

struct BusCrowding {
    let level: CrowdLevel
    let remainingSeats: Int?
    let updatedAt: Date?
    var isDemo: Bool = false

    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 600
    }
}

/// Normalised plate key: keep A–Z / 0–9 only, uppercase. Applied to both the crowding
/// feed's `BusID` and TDX's `PlateNumb` so they join.
func normalizedPlate(_ raw: String) -> String {
    String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        .uppercased()
}

/// Taipei / New Taipei "公車車上即時座位事件" — the live gzip feed from the Taipei bus
/// dynamic-information centre. Keyed by normalised plate.
///
///   https://tcgbusfs.blob.core.windows.net/blobbus/BusSeatEvent.gz
///
/// `AppSettings.crowdingDemoMode` still lets the app synthesise levels if the feed is
/// ever unavailable; those are flagged `isDemo`.
actor CrowdingProvider {
    static let shared = CrowdingProvider()

    private let url = URL(string: "https://tcgbusfs.blob.core.windows.net/blobbus/BusSeatEvent.gz")!
    private var byPlate: [String: BusCrowding] = [:]
    private var fetchedAt: Date = .distantPast

    /// Crowding for the given plates. Falls back to demo synthesis when enabled and the
    /// live feed has nothing for a plate.
    func crowding(forPlates plates: [String], demo: Bool) async -> [String: BusCrowding] {
        await refreshIfNeeded()
        var result: [String: BusCrowding] = [:]
        for plate in plates {
            let key = normalizedPlate(plate)
            if let live = byPlate[key] {
                result[key] = live
            } else if demo {
                result[key] = Self.demoCrowding(forPlate: key)
            }
        }
        return result
    }

    struct FeedStatus {
        let updateTime: Date?
        let recordCount: Int
        var isLive: Bool {
            guard let updateTime else { return false }
            return Date().timeIntervalSince(updateTime) < 1800
        }
    }

    /// One-shot fetch for the diagnostics row in Settings.
    func feedStatus() async -> FeedStatus {
        guard let payload = await fetchDecoded() else {
            return FeedStatus(updateTime: nil, recordCount: 0)
        }
        return FeedStatus(
            updateTime: Fmt.slashDateTime.date(from: payload.essentialInfo?.updateTime ?? ""),
            recordCount: payload.busInfo.count
        )
    }

    private func refreshIfNeeded() async {
        guard Date().timeIntervalSince(fetchedAt) > 20 else { return }
        guard let payload = await fetchDecoded() else { return }   // keep previous cache

        var map: [String: BusCrowding] = [:]
        for e in payload.busInfo {
            guard let raw = e.level, let level = CrowdLevel(rawValue: raw) else { continue }
            map[normalizedPlate(e.busID)] = BusCrowding(
                level: level,
                remainingSeats: e.remainingNum,
                updatedAt: Fmt.spaceDateTime.date(from: e.dataTime)
            )
        }
        byPlate = map
        fetchedAt = Date()
    }

    private func fetchDecoded() async -> SeatEventPayload? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = Gunzip.decompress(data) ?? data   // tolerate an already-plain body
            return try JSONDecoder().decode(SeatEventPayload.self, from: json)
        } catch {
            return nil
        }
    }

    /// Deterministic pseudo-level from the plate string so a given bus stays consistent.
    private static func demoCrowding(forPlate plate: String) -> BusCrowding {
        var hasher = Hasher()
        hasher.combine(plate)
        let bucket = abs(hasher.finalize()) % 10
        let level: CrowdLevel = bucket < 5 ? .comfortable : (bucket < 8 ? .moderate : .crowded)
        let seats = level == .comfortable ? (bucket * 3 + 2) : nil
        return BusCrowding(level: level, remainingSeats: seats, updatedAt: Date(), isDemo: true)
    }

    // MARK: - Feed DTOs

    private struct SeatEventPayload: Decodable {
        let essentialInfo: EssentialInfo?
        let busInfo: [BusSeatEvent]

        enum CodingKeys: String, CodingKey {
            case essentialInfo = "EssentialInfo"
            case busInfo = "BusInfo"
        }
    }

    private struct EssentialInfo: Decodable {
        let updateTime: String?
        enum CodingKeys: String, CodingKey { case updateTime = "UpdateTime" }
    }

    private struct BusSeatEvent: Decodable {
        let busID: String
        let level: Int?
        let remainingNum: Int?
        let dataTime: String

        enum CodingKeys: String, CodingKey {
            case busID = "BusID"
            case level = "Level"
            case remainingNum = "RemainingNum"
            case dataTime = "DataTime"
        }
    }
}
