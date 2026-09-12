import Foundation
import ActivityKit
import UserNotifications

@MainActor
@Observable
final class MetroTripTracker {
    static let shared = MetroTripTracker()

    private(set) var isTracking = false
    private(set) var trackedKey: String?
    private(set) var lastError: String?

    private var activity: Activity<MetroTripAttributes>?
    private var pollTask: Task<Void, Never>?
    private var op: MetroOperator = .trtc
    private var stationID = ""
    private var heading = ""

    var isActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(operator op: MetroOperator, station: MetroLineStation, systemName: String,
               lineName: String, heading: String) async {
        guard isActivitiesEnabled else {
            lastError = "請到「設定 › 交通即時查」開啟即時動態。"
            return
        }
        await stop()
        self.op = op
        self.stationID = station.stationID
        self.heading = heading

        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])

        let attributes = MetroTripAttributes(
            systemName: systemName, lineName: lineName,
            stationName: station.name, heading: heading
        )
        let initial = MetroTripAttributes.ContentState(
            nextArrival: nil, nextEtaMinutes: nil, followingEtaMinutes: nil,
            statusText: "查詢中…", updatedAt: .now
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: Date().addingTimeInterval(120)),
                pushType: nil
            )
            isTracking = true
            trackedKey = "\(op.rawValue)-\(station.stationID)-\(heading)"
            lastError = nil
            TripKeepAlive.shared.acquire()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(20))
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        let wasTracking = isTracking
        pollTask?.cancel(); pollTask = nil
        if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
        activity = nil
        isTracking = false
        trackedKey = nil
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func refresh() async {
        guard let activity else { return }
        guard let board = try? await MetroService.shared.liveBoard(operator: op, stationID: stationID) else { return }
        let matching = board.filter { $0.headingText == heading || $0.tripHeadSign == heading }
        let sorted = (matching.isEmpty ? board : matching).sorted { ($0.estimateTime ?? 99) < ($1.estimateTime ?? 99) }

        let first = sorted.first
        let second = sorted.dropFirst().first
        let eta = first?.estimateTime
        let arrival = eta.map { Date().addingTimeInterval(TimeInterval(max($0, 0) * 60)) }
        let status: String
        if first?.serviceStatus == 1 { status = "暫停營運" }
        else if let e = eta { status = e <= 0 ? "進站中" : "\(e) 分" }
        else { status = "—" }

        let state = MetroTripAttributes.ContentState(
            nextArrival: arrival,
            nextEtaMinutes: eta,
            followingEtaMinutes: second?.estimateTime,
            statusText: status,
            updatedAt: .now
        )
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
    }
}
