import Foundation
import ActivityKit
import UserNotifications

/// Drives a `RailTripAttributes` Live Activity for one saved ticket:
/// countdown to departure → arrival, live TRA delay, arrival/boarding notification.
@MainActor
@Observable
final class RailTripTracker {
    static let shared = RailTripTracker()

    private(set) var isTracking = false
    private(set) var trackedTrainNo: String?
    private(set) var lastError: String?

    private var activity: Activity<RailTripAttributes>?
    private var pollTask: Task<Void, Never>?
    private var notifiedBoarding = false

    struct Snapshot {
        let system: RailSystem
        let trainNo: String
        let trainLabel: String
        let fromID: String
        let fromName: String
        let toName: String
        let depTime: String
        let arrTime: String
        let seatLabel: String
        let depDate: Date?
        let arrDate: Date?
    }
    private var snap: Snapshot?
    private var platform: String?
    private var stage: TripStage = .awaitingBoard
    private var ratingSince: Date?

    var isActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(ticket: RailTicket) async {
        guard isActivitiesEnabled else {
            lastError = "請到「設定 › 交通即時查」開啟即時動態。"
            return
        }
        await stop()

        platform = nil
        let snapshot = Snapshot(
            system: ticket.system,
            trainNo: ticket.trainNo,
            trainLabel: ticket.trainLabel,
            fromID: ticket.fromStationID,
            fromName: ticket.fromName,
            toName: ticket.toName,
            depTime: ticket.depTime,
            arrTime: ticket.arrTime,
            seatLabel: ticket.seatLabel,
            depDate: ticket.departureDate,
            arrDate: ticket.arrivalDate
        )
        snap = snapshot
        notifiedBoarding = false
        stage = .awaitingBoard
        ratingSince = nil
        TripInteraction.consume()
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])

        let attributes = RailTripAttributes(
            systemName: snapshot.system.displayName,
            trainLabel: snapshot.trainLabel,
            fromName: snapshot.fromName,
            toName: snapshot.toName,
            depTime: snapshot.depTime,
            arrTime: snapshot.arrTime,
            seatLabel: snapshot.seatLabel
        )
        let initial = RailTripAttributes.ContentState(
            phase: "距發車", targetDate: snapshot.depDate, delayMinutes: 0,
            currentStatus: nil, updatedAt: .now,
            adjustedDepart: snapshot.depDate, adjustedArrive: snapshot.arrDate,
            hint: nil, platform: nil, stage: .awaitingBoard, rating: nil
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: Date().addingTimeInterval(300)),
                pushType: nil
            )
            isTracking = true
            trackedTrainNo = snapshot.trainNo
            lastError = nil
            TripKeepAlive.shared.acquire()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(45))
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
        snap = nil
        isTracking = false
        trackedTrainNo = nil
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func refresh() async {
        guard let snap, let activity else { return }

        if let action = TripInteraction.consume() {
            switch action {
            case "advance":
                if stage == .awaitingBoard { stage = .riding }
                else if stage == .riding || stage == .awaitingAlight { stage = .rating; ratingSince = .now }
            case let r where r.hasPrefix("rate:"):
                let n = Int(r.dropFirst(5)) ?? 0
                TripInteraction.recordRating(n, route: snap.trainLabel,
                                             from: snap.fromName, to: snap.toName)
                RatingService.submit(stars: n, kind: "rail", route: snap.trainLabel,
                                     from: snap.fromName, to: snap.toName,
                                     system: snap.system.displayName)
                stage = .done
            default: break
            }
        }
        if stage == .done { await endTrip(); return }
        if stage == .rating, let since = ratingSince, since.timeIntervalSinceNow < -180 {
            await endTrip(); return
        }

        var delay = 0
        var statusText: String?
        if snap.system == .tra,
           let live = try? await RailService.shared.liveStatus(system: .tra, trainNo: snap.trainNo) {
            delay = max(0, live.delayMinutes)
            statusText = live.statusText
        }

        // Platform: TRA only, and only worth fetching around departure. Cache once known.
        if snap.system == .tra, platform == nil,
           let dep = snap.depDate, dep.timeIntervalSinceNow < 1800, dep.timeIntervalSinceNow > -600 {
            platform = await RailService.shared.traPlatform(stationID: snap.fromID, trainNo: snap.trainNo)
        }

        let now = Date()
        let dep = snap.depDate.map { $0.addingTimeInterval(TimeInterval(delay * 60)) }
        let arr = snap.arrDate.map { $0.addingTimeInterval(TimeInterval(delay * 60)) }

        var phase: String
        let target: Date?
        var hint: String?
        if let dep, now < dep {
            phase = "距發車"; target = dep
            let s = dep.timeIntervalSince(now)
            if s < 180 { hint = "到月台候車，上車後點靈動島確認" }
            else if s < 600 { hint = "前往月台" }
        } else if let arr, now < arr {
            phase = "行駛中"; target = arr
            let s = arr.timeIntervalSince(now)
            if s < 300 { hint = "請收拾隨身物品，準備下車" }
            else if s < 900 { hint = "即將抵達，請準備" }
        } else {
            phase = "已抵達"; target = nil
        }

        // --- Stage machine ---
        if stage == .awaitingBoard, let dep, now.timeIntervalSince(dep) > 600 {
            stage = .riding   // long past departure with no confirm → assume aboard
        }
        if (stage == .riding || stage == .awaitingBoard), phase == "已抵達" {
            stage = .awaitingAlight
        }
        switch stage {
        case .awaitingBoard: hint = (target != nil && (target!.timeIntervalSinceNow < 300)) ? "車來了！上車後點靈動島確認" : hint
        case .awaitingAlight: phase = "已抵達"; hint = "下車後點靈動島確認"
        case .rating: phase = "行程評分"; hint = "為這趟行程評分"
        case .done: phase = "感謝評分"; hint = nil
        default: break
        }

        let state = RailTripAttributes.ContentState(
            phase: phase, targetDate: target, delayMinutes: delay,
            currentStatus: statusText, updatedAt: now,
            adjustedDepart: dep, adjustedArrive: arr, hint: hint,
            platform: (stage == .awaitingBoard || phase == "距發車") ? platform : nil,
            stage: stage, rating: nil
        )
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
        )

        if phase == "距發車", let dep, dep.timeIntervalSinceNow < 300, !notifiedBoarding {
            notifiedBoarding = true
            notify(title: "\(snap.trainLabel) 即將發車",
                   body: "\(snap.fromName) → \(snap.toName)　\(snap.seatLabel)".trimmingCharacters(in: .whitespaces))
        }
    }

    private func endTrip() async {
        let wasTracking = isTracking
        if let activity {
            var s = activity.content.state
            s.stage = .done; s.phase = "感謝評分"; s.hint = nil
            await activity.end(ActivityContent(state: s, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(10)))
        }
        pollTask?.cancel()
        self.activity = nil
        isTracking = false
        trackedTrainNo = nil
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "train-\(title)", content: content, trigger: nil)
        )
    }
}
