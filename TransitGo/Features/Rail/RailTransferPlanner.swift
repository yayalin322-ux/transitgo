import Foundation

/// One ride on one TRA train, from `fromStation` to `toStation`.
struct RailLeg: Identifiable, Hashable {
    let id = UUID()
    let train: TrainRun
    let fromStation: RailStation
    let toStation: RailStation

    static func == (l: RailLeg, r: RailLeg) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RailItinerary: Identifiable {
    let id = UUID()
    let legs: [RailLeg]
    var isDirect: Bool { legs.count == 1 }
    /// Minutes actually waiting at the junction, for the transfer case.
    var transferWaitMinutes: Int? {
        guard legs.count == 2,
              let arr = RailTransferPlanner.minutesOfDay(legs[0].train.arrival),
              let dep = RailTransferPlanner.minutesOfDay(legs[1].train.departure) else { return nil }
        return dep - arr
    }
}

/// TRA has no "routes" the way buses do — every train is its own scheduled run with its
/// own stop times, and most branch lines (平溪、內灣、六家、集集) don't through-run onto
/// the main line, so reaching one from an arbitrary main-line station usually means an
/// actual transfer at a specific junction station, on a specific *connecting* train — not
/// just "any later train". This does that schedule matching, the same way a human would
/// with two timetables open: search origin→junction and junction→destination separately,
/// then keep only pairs where the connecting train actually departs after the first one
/// arrives (with a sane minimum/maximum wait).
enum RailTransferPlanner {
    /// Candidate transfer points: both where branch lines split off the main line, AND
    /// major trunk stations where switching from a fast train to a local one (or vice
    /// versa) is a completely normal thing to do — e.g. 台北→竹北 is often faster changing
    /// at 新竹 onto a train that actually stops at 竹北, than waiting for a through train
    /// that does. A fixed list of only branch junctions was missing this whole category.
    private static let transferCandidateNames = [
        // Branch-line junctions
        "八堵", "瑞芳", "三貂嶺", "猴硐", "竹中", "二水",
        // Major west-coast trunk stations (fast/local transfer points)
        "基隆", "七堵", "台北", "板橋", "桃園", "中壢", "新竹", "竹南",
        "苗栗", "豐原", "台中", "彰化", "員林", "斗六", "嘉義", "台南",
        "岡山", "高雄", "鳳山", "潮州", "枋寮",
        // East line
        "宜蘭", "羅東", "花蓮", "玉里", "台東",
    ]

    private static let minTransferMinutes = 5
    private static let maxTransferMinutes = 90

    static func plan(from origin: RailStation, to destination: RailStation, date: Date) async -> [RailItinerary] {
        await RailStationStore.shared.loadIfNeeded()
        let allStations = await RailStationStore.shared.stations(for: .tra)

        async let directTask = (try? await RailService.shared.timetable(system: .tra, from: origin, to: destination, date: date)) ?? []

        let junctions = transferCandidateNames
            .compactMap { name in allStations.first(where: { $0.name == name }) }
            .filter { $0.id != origin.id && $0.id != destination.id }

        async let transferTask: [RailItinerary] = withTaskGroup(of: [RailItinerary].self) { group in
            for junction in junctions {
                group.addTask {
                    async let leg1Task = try? RailService.shared.timetable(system: .tra, from: origin, to: junction, date: date)
                    async let leg2Task = try? RailService.shared.timetable(system: .tra, from: junction, to: destination, date: date)
                    let leg1s = await leg1Task ?? []
                    let leg2s = await leg2Task ?? []
                    guard !leg1s.isEmpty, !leg2s.isEmpty else { return [] }

                    var pairs: [RailItinerary] = []
                    for l1 in leg1s {
                        guard let arr = minutesOfDay(l1.arrival) else { continue }
                        for l2 in leg2s {
                            guard let dep = minutesOfDay(l2.departure) else { continue }
                            let wait = dep - arr
                            if wait >= minTransferMinutes, wait <= maxTransferMinutes {
                                pairs.append(RailItinerary(legs: [
                                    RailLeg(train: l1, fromStation: origin, toStation: junction),
                                    RailLeg(train: l2, fromStation: junction, toStation: destination),
                                ]))
                            }
                        }
                    }
                    return pairs
                }
            }
            var out: [RailItinerary] = []
            for await pairs in group { out += pairs }
            return out
        }

        // Direct and transfer are computed *together*, not "try direct, only look at
        // transfers if that came back empty" — a transfer can genuinely be the faster
        // option even when a (slow, all-stops) direct train also exists.
        let direct = await directTask
        var transfers = await transferTask

        var results: [RailItinerary] = direct.map {
            RailItinerary(legs: [RailLeg(train: $0, fromStation: origin, toStation: destination)])
        }
        // One option per departure-time bucket so the transfer list isn't 30 near-duplicates.
        transfers.sort { totalDurationMinutes($0) < totalDurationMinutes($1) }
        var seenDepartureHours = Set<Int>()
        for r in transfers {
            let hourKey = (minutesOfDay(r.legs[0].train.departure) ?? 0) / 30
            if seenDepartureHours.insert(hourKey).inserted { results.append(r) }
        }

        // Fastest total door-to-door time first, whether direct or a transfer.
        results.sort { totalDurationMinutes($0) < totalDurationMinutes($1) }
        return Array(results.prefix(6))
    }

    private static func totalDurationMinutes(_ itinerary: RailItinerary) -> Int {
        guard let dep = minutesOfDay(itinerary.legs.first?.train.departure ?? ""),
              let arr = minutesOfDay(itinerary.legs.last?.train.arrival ?? "") else { return .max }
        let mins = arr - dep
        return mins >= 0 ? mins : mins + 24 * 60   // crosses midnight
    }

    fileprivate static func minutesOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
