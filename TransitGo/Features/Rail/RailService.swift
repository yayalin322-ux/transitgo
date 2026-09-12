import Foundation

@MainActor
@Observable
final class RailStationStore {
    static let shared = RailStationStore()

    private(set) var tra: [RailStation] = []
    private(set) var thsr: [RailStation] = []
    var loadError: String?

    func loadIfNeeded() async {
        do {
            if tra.isEmpty {
                let resp: TRAStationResponse = try await TDXClient.shared.get("v3/Rail/TRA/Station")
                tra = resp.stations.map { RailStation(id: $0.stationID, name: $0.stationName.display) }
            }
            if thsr.isEmpty {
                let resp: [THSRStation] = try await TDXClient.shared.get("v2/Rail/THSR/Station")
                thsr = resp.map { RailStation(id: $0.stationID, name: $0.stationName.display) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func stations(for system: RailSystem) -> [RailStation] {
        system == .tra ? tra : thsr
    }
}

struct RailService {
    static let shared = RailService()

    /// TRA live delay for one train (nil for THSR — no per-train live feed in the basic tier).
    func liveStatus(system: RailSystem, trainNo: String) async throws -> TrainLiveStatus? {
        guard system == .tra else { return nil }
        let resp: TRALiveBoardResponse = try await TDXClient.shared.get(
            "v3/Rail/TRA/TrainLiveBoard",
            query: ["$filter": "TrainNo eq '\(trainNo)'"]
        )
        guard let b = resp.trainLiveBoards.first else { return nil }
        return TrainLiveStatus(
            delayMinutes: b.delayTime ?? 0,
            stationName: b.stationName.display,
            status: b.trainStationStatus
        )
    }

    /// TRA boarding platform for a train at a station, if the live board publishes it yet
    /// (usually populated ~15–20 min before arrival). THSR has no equivalent basic feed.
    func traPlatform(stationID: String, trainNo: String) async -> String? {
        let resp: TRAStationLiveBoardResponse? = try? await TDXClient.shared.get(
            "v3/Rail/TRA/StationLiveBoard",
            query: ["$filter": "StationID eq '\(stationID)' and TrainNo eq '\(trainNo)'"]
        )
        let p = resp?.stationLiveBoards.first?.platform?.trimmingCharacters(in: .whitespaces)
        return (p?.isEmpty == false) ? p : nil
    }

    /// Full stop list for one train (today only — TDX only exposes "Today/TrainNo").
    func trainDetail(system: RailSystem, trainNo: String) async throws -> RailTrainDetail? {
        switch system {
        case .tra:
            let resp: TRATimetableResponse = try await TDXClient.shared.get(
                "v3/Rail/TRA/DailyTrainTimetable/Today/TrainNo/\(trainNo)"
            )
            guard let tt = resp.trainTimetables.first else { return nil }
            let info = tt.trainInfo
            return RailTrainDetail(
                trainNo: info.trainNo,
                trainType: info.trainTypeName.display,
                stops: tt.stopTimes.enumerated().map { i, s in
                    RailTrainStop(sequence: i, stationID: s.stationID,
                                  stationName: s.stationName?.display ?? s.stationID,
                                  arrival: s.arrivalTime, departure: s.departureTime)
                },
                tripLine: info.tripLine,
                note: (info.note?.isEmpty == true) ? nil : info.note,
                hasWheelChair: info.wheelChairFlag == 1,
                hasBike: info.bikeFlag == 1,
                hasDining: info.diningFlag == 1,
                hasBreastFeed: info.breastFeedFlag == 1,
                hasPackageService: info.packageServiceFlag == 1
            )
        case .thsr:
            let resp: [THSRDailyTrain] = try await TDXClient.shared.get(
                "v2/Rail/THSR/DailyTimetable/Today/TrainNo/\(trainNo)"
            )
            guard let t = resp.first else { return nil }
            return RailTrainDetail(
                trainNo: t.dailyTrainInfo.trainNo,
                trainType: "高鐵",
                stops: t.stopTimes
                    .sorted { ($0.stopSequence ?? 0) < ($1.stopSequence ?? 0) }
                    .enumerated().map { i, s in
                        RailTrainStop(sequence: i, stationID: s.stationID,
                                      stationName: s.stationName.display,
                                      arrival: s.arrivalTime, departure: s.departureTime)
                    }
            )
        }
    }

    /// THSR standard/business seat availability for trains departing a station soon.
    func thsrSeatStatus(stationID: String) async throws -> [THSRSeatTrain] {
        let resp: THSRSeatStatusResponse = try await TDXClient.shared.get(
            "v2/Rail/THSR/AvailableSeatStatusList/\(stationID)"
        )
        return resp.availableSeats
    }

    func timetable(system: RailSystem, from: RailStation, to: RailStation, date: Date) async throws -> [TrainRun] {
        let dateStr = Fmt.apiDate.string(from: date)
        switch system {
        case .tra:
            let resp: TRATimetableResponse = try await TDXClient.shared.get(
                "v3/Rail/TRA/DailyTrainTimetable/OD/\(from.id)/to/\(to.id)/\(dateStr)"
            )
            return resp.trainTimetables.compactMap { tt in
                guard
                    let dep = tt.stopTimes.first(where: { $0.stationID == from.id })?.departureTime,
                    let arr = tt.stopTimes.first(where: { $0.stationID == to.id })?.arrivalTime
                else { return nil }
                return TrainRun(
                    trainNo: tt.trainInfo.trainNo,
                    trainType: tt.trainInfo.trainTypeName.display,
                    departure: dep,
                    arrival: arr,
                    note: tt.trainInfo.note?.isEmpty == true ? nil : tt.trainInfo.note
                )
            }
            .sorted { $0.departure < $1.departure }

        case .thsr:
            let resp: [THSRODTimetable] = try await TDXClient.shared.get(
                "v2/Rail/THSR/DailyTimetable/OD/\(from.id)/to/\(to.id)/\(dateStr)"
            )
            return resp.compactMap { t in
                guard
                    let dep = t.originStopTime.departureTime,
                    let arr = t.destinationStopTime.arrivalTime
                else { return nil }
                return TrainRun(
                    trainNo: t.dailyTrainInfo.trainNo,
                    trainType: "",
                    departure: dep,
                    arrival: arr,
                    note: nil
                )
            }
            .sorted { $0.departure < $1.departure }
        }
    }
}
