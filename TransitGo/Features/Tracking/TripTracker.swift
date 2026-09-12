import Foundation
import ActivityKit
import UserNotifications

/// Drives a `BusTripAttributes` Live Activity for one tracked bus ride:
/// waiting to board at `boardStop`, then riding to `alightStop`. Polls TDX for
/// ETA / vehicle position and fires board + alight reminders.
@MainActor
@Observable
final class TripTracker {
    static let shared = TripTracker()

    private(set) var isTracking = false
    private(set) var lastError: String?

    private var activity: Activity<BusTripAttributes>?
    private var pollTask: Task<Void, Never>?

    private var notifiedBoardApproach = false
    private var notifiedBoardArrive = false
    private var notifiedAlightApproach = false
    private var notifiedAlightArrive = false
    /// Plate we locked onto once the bus reached the board stop.
    private var capturedPlate: String?
    private var onboard = false
    private var stage: TripStage = .awaitingBoard
    private var ratingSince: Date?
    private var skipPlates: Set<String> = []
    /// Highest stop-sequence we've actually observed `capturedPlate` at this trip — lets
    /// us notice when the *same plate* shows up again on a later loop of the route (city
    /// buses run round trips all day) instead of quietly "reconnecting" to that new run.
    private var maxSeqSeen: Int?
    /// When a candidate bus was first captured (pending board confirmation). If the user
    /// never taps 我上車了/看下一班, we default to "you boarded the nearest bus" after a
    /// grace period rather than waiting on positional proof, which can lag behind reality.
    private var capturedAt: Date?

    struct Target {
        let scope: BusScope
        let routeName: String
        let direction: Int
        let boardStop: BusRouteStop
        let alightStop: BusRouteStop
        let destinationName: String
        let seat: String?
        var plate: String?
        /// True when `boardStop` is the first stop of this direction — at a terminus you
        /// can board whichever bus is sitting there, so the "是這台嗎？" match-a-specific
        /// -incoming-bus flow is pointless and this trip starts straight in `.riding`.
        var isOriginStop: Bool = false
    }

    private var target: Target?

    var isActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(_ target: Target) async {
        guard isActivitiesEnabled else {
            lastError = "請到「設定 › 交通即時查」開啟即時動態。"
            return
        }
        await stop()

        self.target = target
        notifiedBoardApproach = false
        notifiedBoardArrive = false
        notifiedAlightApproach = false
        notifiedAlightArrive = false
        capturedPlate = target.plate
        maxSeqSeen = nil
        capturedAt = nil
        // At an origin stop any bus sitting there is boardable — skip the "is this the
        // one?" candidate-matching flow entirely and start straight in .riding.
        onboard = target.isOriginStop
        stage = target.isOriginStop ? .riding : .awaitingBoard
        ratingSince = nil
        skipPlates = []
        TripInteraction.consume()   // clear any stale action
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])

        let attributes = BusTripAttributes(
            routeName: target.routeName,
            scopeName: target.scope.displayName,
            boardStopName: target.boardStop.stopName.display,
            alightStopName: target.alightStop.stopName.display,
            destinationName: target.destinationName,
            seat: target.seat
        )
        let initial = BusTripAttributes.ContentState(
            etaDate: nil, stopsAway: nil,
            statusText: target.isOriginStop ? "起站可隨時上車" : "等待班車",
            plate: target.plate, crowdingRaw: nil, updatedAt: .now,
            hint: target.isOriginStop ? "記得提前按下車鈴" : "上車後點一下靈動島確認",
            onboard: target.isOriginStop, stage: stage, rating: nil
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: Date().addingTimeInterval(180)),
                pushType: nil
            )
            isTracking = true
            lastError = nil
            TripKeepAlive.shared.acquire()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshOnce()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        let wasTracking = isTracking
        pollTask?.cancel()
        pollTask = nil
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        target = nil
        isTracking = false
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func refreshOnce() async {
        guard let target, let activity else { return }
        let stageBefore = stage

        // --- Apply any button the user tapped on the Live Activity ---
        if let action = TripInteraction.consume() {
            switch action {
            case "advance":
                if stage == .awaitingBoard {
                    stage = .riding; onboard = true
                    maxSeqSeen = nil   // fresh baseline for the bus we just confirmed boarding
                    capturedAt = nil
                    ObservationService.shared.report(
                        route: target.routeName, plate: capturedPlate,
                        stopUID: target.boardStop.stopUID, stopName: target.boardStop.stopName.display,
                        stopSequence: target.boardStop.stopSequence, kind: "board",
                        system: target.scope.displayName)
                } else if stage == .riding || stage == .awaitingAlight {
                    stage = .rating; ratingSince = .now
                    ObservationService.shared.report(
                        route: target.routeName, plate: capturedPlate,
                        stopUID: target.alightStop.stopUID, stopName: target.alightStop.stopName.display,
                        stopSequence: target.alightStop.stopSequence, kind: "alight",
                        system: target.scope.displayName)
                }
            case "nextbus":
                if let p = capturedPlate ?? target.plate { skipPlates.insert(p) }
                capturedPlate = nil
                maxSeqSeen = nil
                capturedAt = nil
            case let r where r.hasPrefix("rate:"):
                let n = Int(r.dropFirst(5)) ?? 0
                TripInteraction.recordRating(n, route: target.routeName,
                                             from: target.boardStop.stopName.display,
                                             to: target.alightStop.stopName.display)
                RatingService.submit(stars: n, kind: "bus", route: target.routeName,
                                     from: target.boardStop.stopName.display,
                                     to: target.alightStop.stopName.display,
                                     system: target.scope.displayName)
                stage = .done
            default: break
            }
        }
        if stage == .done { await endWithArrivalState(); return }
        // Rating prompt shown too long with no tap → just end.
        if stage == .rating, let since = ratingSince, since.timeIntervalSinceNow < -180 {
            await endWithArrivalState(); return
        }

        do {
            async let estimatesTask = BusService.shared.estimates(scope: target.scope, routeName: target.routeName)
            async let busesTask = BusService.shared.liveBuses(scope: target.scope, routeName: target.routeName)
            let estimates = try await estimatesTask
            let buses = try await busesTask
            let dirBuses = (buses[target.direction] ?? []).filter { !skipPlates.contains($0.plate) }

            // --- Which bus are we watching? ---
            var tracked: LiveBus?
            if onboard || target.plate != nil {
                let plate = capturedPlate ?? target.plate
                let match = dirBuses.first { $0.plate == plate }
                // A city bus runs the route several times a day — the *same plate*
                // showing up again with a much lower stopSequence means it started a
                // new loop, not that we're still riding it. Don't silently reattach.
                if let t = match, let maxSeq = maxSeqSeen, t.stopSequence < maxSeq - 3 {
                    if onboard { stage = .rating; ratingSince = ratingSince ?? .now }
                    if let plate { skipPlates.insert(plate) }
                    capturedPlate = nil
                    capturedAt = nil
                } else {
                    tracked = match
                    if let t = match { maxSeqSeen = max(maxSeqSeen ?? t.stopSequence, t.stopSequence) }
                    // TDX dropped the bus mid-trip → fall back to the last user-reported stop.
                    if tracked == nil, let plate,
                       let seq = ObservationService.shared.estimatedStopSequence(plate: plate) {
                        tracked = LiveBus(plate: plate, stopSequence: seq, atStop: false,
                                          crowding: nil, isLowFloor: false, hasLift: false)
                    }
                }
            } else {
                // Next bus that will reach the board stop.
                tracked = dirBuses
                    .filter { $0.stopSequence <= target.boardStop.stopSequence }
                    .max(by: { $0.stopSequence < $1.stopSequence })
            }

            // --- Auto-advance fallbacks so the LA never gets stuck if the user ignores it ---
            if stage == .awaitingBoard, let t = tracked, t.stopSequence >= target.boardStop.stopSequence,
               capturedPlate == nil {
                capturedPlate = t.plate   // remember which bus is here, pending user confirm
                capturedAt = .now
            }
            // Positional proof it left the stop — confirms boarding fast when it's clear.
            if stage == .awaitingBoard, let t = tracked, t.stopSequence > target.boardStop.stopSequence {
                stage = .riding; onboard = true; capturedAt = nil
            }
            // No positional proof yet (TDX lag) but the user hasn't said otherwise either —
            // default to "you got on the nearest bus" rather than leaving the prompt stuck.
            if stage == .awaitingBoard, let capturedAt, Date().timeIntervalSince(capturedAt) > 90 {
                stage = .riding; onboard = true
                self.capturedAt = nil
            }
            onboard = (stage != .awaitingBoard)
            if onboard, capturedPlate == nil { capturedPlate = tracked?.plate }

            let activeStop = onboard ? target.alightStop : target.boardStop
            let est = estimates["\(target.direction)-\(activeStop.stopUID)"]
            let stopsAway = tracked.map { activeStop.stopSequence - $0.stopSequence }

            let etaSeconds = est?.isActionable == true ? est?.estimateTime : nil
            let etaDate = etaSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }

            let status: String
            switch est?.stopStatus {
            case 1: status = "尚未發車"
            case 3: status = "末班已過"
            case 4: status = "今日未營運"
            default:
                if let n = stopsAway, n <= 0 { status = onboard ? "本站下車" : "進站中" }
                else if let s = etaSeconds, s < 60 { status = "即將進站" }
                else if let n = stopsAway, n > 0 { status = "約 \(n) 站後到站" }
                else if let s = etaSeconds { status = "約 \(Int((Double(s) / 60).rounded())) 分後到站" }
                else { status = "等待班車資訊" }
            }

            let approaching = (stopsAway.map { $0 <= 2 } ?? false) || (etaSeconds.map { $0 < 180 } ?? false)
            let arriving = (stopsAway.map { $0 <= 0 } ?? false) || (etaSeconds.map { $0 < 45 } ?? false)
            let serviceEnded = est?.stopStatus == 1 || est?.stopStatus == 3 || est?.stopStatus == 4

            // riding → awaitingAlight a stop early (heads-up before arrival, not exactly at
            // it — TDX's own polling lag means "right at the stop" can be too late to react
            // to); passed the stop → rating
            if stage == .riding, (stopsAway.map { $0 <= 1 } ?? false) { stage = .awaitingAlight }
            if (stage == .riding || stage == .awaitingAlight), (stopsAway.map { $0 < -1 } ?? false) {
                stage = .rating; ratingSince = .now
            }

            let hint: String?
            switch stage {
            case .awaitingBoard:
                hint = arriving ? "車來了！上車後點靈動島確認" : (approaching ? "看到車記得舉手招車" : "上車後點一下靈動島確認")
            case .riding:
                hint = approaching ? "記得提前按下車鈴" : nil
            case .awaitingAlight:
                hint = "下車後點靈動島確認"
            case .rating:
                hint = "為這趟行程評分"
            case .done:
                hint = nil
            }

            let state = BusTripAttributes.ContentState(
                etaDate: etaDate,
                stopsAway: stopsAway,
                statusText: serviceEnded ? status : (stage == .rating ? "為這趟評分" : status),
                plate: capturedPlate ?? target.plate ?? tracked?.plate ?? est?.plate,
                crowdingRaw: tracked?.crowding?.level.rawValue,
                updatedAt: .now,
                hint: hint,
                onboard: onboard,
                stage: stage,
                rating: nil
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
            // There's no API to force the Dynamic Island's compact bubble open into the
            // full expanded view — that's reserved for a user long-press. The closest
            // equivalent we get is `alertConfiguration`: a brief haptic + system banner
            // at the moment that actually matters (entering the "get off soon" heads-up).
            if stageBefore != .awaitingAlight, stage == .awaitingAlight {
                await activity.update(content, alertConfiguration: .init(
                    title: "快到站了", body: "「\(target.alightStop.stopName.display)」快到了，準備下車", sound: .default
                ))
            } else {
                await activity.update(content)
            }

            // --- Notifications ---
            if !serviceEnded, stage != .rating, stage != .done {
                if !onboard {
                    if approaching, !arriving, !notifiedBoardApproach {
                        notifiedBoardApproach = true
                        notify(id: "board-approach",
                               title: "\(target.routeName) 快到站了",
                               body: stopsAway.map { "還有 \($0) 站到「\(target.boardStop.stopName.display)」，看到車記得舉手招車" }
                                     ?? "「\(target.boardStop.stopName.display)」快到了，準備舉手招車")
                    }
                    if arriving, !notifiedBoardArrive {
                        notifiedBoardArrive = true
                        notify(id: "board-arrive",
                               title: "\(target.routeName) 進站",
                               body: "「\(target.boardStop.stopName.display)」— 上車")
                    }
                } else {
                    if approaching, !arriving, !notifiedAlightApproach {
                        notifiedAlightApproach = true
                        notify(id: "alight-approach",
                               title: "準備下車",
                               body: stopsAway.map { "還有 \($0) 站到「\(target.alightStop.stopName.display)」，記得提前按下車鈴" }
                                     ?? "快到「\(target.alightStop.stopName.display)」，記得按下車鈴")
                    }
                    if arriving, !notifiedAlightArrive {
                        notifiedAlightArrive = true
                        notify(id: "alight-arrive",
                               title: "「\(target.alightStop.stopName.display)」到了",
                               body: "準備下車，記得帶好隨身物品")
                    }
                }
            }

            // --- End: only auto-end on service outage; otherwise the user ends it by rating. ---
            if est?.stopStatus == 3 || est?.stopStatus == 4 {
                await endWithArrivalState()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func endWithArrivalState() async {
        guard let activity else { return }
        let wasTracking = isTracking
        let final = BusTripAttributes.ContentState(
            etaDate: nil, stopsAway: 0, statusText: "行程結束",
            plate: nil, crowdingRaw: nil, updatedAt: .now,
            hint: nil, onboard: true, stage: .done, rating: nil
        )
        await activity.end(
            ActivityContent(state: final, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(120))
        )
        pollTask?.cancel()
        self.activity = nil
        isTracking = false
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "bus-\(id)", content: content, trigger: nil)
        )
    }
}
