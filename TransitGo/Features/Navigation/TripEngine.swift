import Foundation

/// The navigation brain: a pure state machine over a `TripSession`. It receives REAL location fixes (from
/// CoreLocation, or from a test), the clock, and realtime results, and decides — deterministically — which leg
/// the rider is on, what to do next, when to warn about a transfer, when they have arrived, and when the plan no
/// longer fits (off route / missed departure / severe delay). It never touches CoreLocation, the network or SwiftUI,
/// and never plans a route: asking for a new plan is the service's job, triggered by an event this returns.
struct TripEngine {
    private(set) var session: TripSession

    private struct Memory {
        var arrivalStreak = 0
        var offRouteStreak = 0
        var offRouteSince: Date?
        var lastUsableFix: TripFix?
        var prevFix: TripFix?
    }
    private var mem = Memory()

    /// The last fixes put the rider outside the leg's corridor long enough to matter (cleared when back on route or re-planned).
    private(set) var isOffRoute = false

    init(session: TripSession) {
        self.session = session
        if let fix = session.currentLocation, fix.isUsable { mem.lastUsableFix = fix }
    }

    // MARK: Creating a session

    static func makeSession(plan: TripPlan, origin: TripEndpoint, destination: TripEndpoint, now: Date, locationAuthorized: Bool, tripId: UUID = UUID(), reroutes: Int = 0) -> TripSession {
        TripSession(
            tripId: tripId, routeId: plan.routeId, origin: origin, destination: destination, startedAt: now,
            plan: plan, currentLegIndex: 0, status: .notStarted, progress: 0,
            currentLocation: nil, remainingDistanceMeters: nil, remainingDurationSeconds: nil,
            current: nil, nextAction: nil, nextStop: nil, nextTransfer: nil,
            legEnteredAt: now, lastUpdatedAt: now, locationAuthorized: locationAuthorized, reroutes: reroutes
        )
    }

    /// The last usable fix, but ONLY while it is recent: a fix from before the rider went underground says nothing
    /// about where they are now, so guidance falls back to the timetable instead of trusting it.
    private func freshFix(at now: Date) -> TripFix? {
        guard let f = mem.lastUsableFix, now.timeIntervalSince(f.timestamp) <= TripPolicy.freshFixSeconds else { return nil }
        return f
    }

    // MARK: Inputs

    mutating func begin(now: Date) -> [TripEvent] {
        var events: [TripEvent] = [.started(routeId: session.routeId)]
        if session.plan.legs.isEmpty { session.status = .arrived; events.append(.completed); return events }
        session.legEnteredAt = now
        refresh(now: now, fix: nil)
        return events
    }

    /// A new location fix. Position-driven progress happens here.
    mutating func ingest(_ fix: TripFix, now: Date) -> [TripEvent] {
        session.currentLocation = fix
        defer { mem.prevFix = fix; if fix.isUsable { mem.lastUsableFix = fix } }
        return evaluate(now: now, fix: fix.isUsable ? fix : nil)
    }

    /// Time passing with no new fix (a timer): schedule-driven progress, e.g. an underground ride.
    mutating func tick(now: Date) -> [TripEvent] {
        evaluate(now: now, fix: nil)
    }

    /// Realtime result for the WHOLE route (the service asks once per refresh). Only real delays/estimates are kept.
    mutating func apply(overlay: RealtimeOverlay, now: Date) -> [TripEvent] {
        var events: [TripEvent] = []
        session.realtime = .live
        session.realtimeUpdatedAt = now
        session.announced.remove("rtdown")
        for leg in overlay.legs {
            guard session.plan.legs.indices.contains(leg.index) else { continue }
            let planned = session.plan.legs[leg.index]
            if leg.status?.state == .cancelled {
                if session.cancelledLegs.insert(leg.index).inserted, planned.index >= session.currentLegIndex {
                    events.append(.rerouteSuggested(reason: .cancelled))
                }
            }
            if planned.isTimetabled, let delay = leg.status?.delaySeconds {
                let old = session.delayByLeg[leg.index]
                session.delayByLeg[leg.index] = delay
                if planned.index >= session.currentLegIndex, delay >= TripPolicy.delayAlertSeconds, abs(delay - (old ?? 0)) >= TripPolicy.delayRealertChange {
                    events.append(.delayed(legIndex: leg.index, seconds: delay))
                }
                if delay >= TripPolicy.severeDelaySeconds, planned.index >= session.currentLegIndex, announce("severe:\(leg.index)") {
                    events.append(.rerouteSuggested(reason: .severeDelay))
                }
            } else if let est = leg.estimatedTime.flatMap({ RealtimeTime.parse($0) }), !planned.isTimetabled, leg.status?.state != .cancelled {
                session.etaByLeg[leg.index] = est      // a headway vehicle's real ETA at the boarding stop
            }
        }
        refresh(now: now, fix: freshFix(at: now))
        return events
    }

    /// Realtime could not be read: guidance continues from the timetable, and says so.
    mutating func realtimeFailed(now: Date) -> [TripEvent] {
        session.realtime = .unavailable
        // Old realtime numbers are no longer trustworthy as "now": guidance goes back to the timetable, and says so.
        session.etaByLeg = [:]
        session.delayByLeg = [:]
        refresh(now: now, fix: freshFix(at: now))
        return session.announced.insert("rtdown").inserted ? [.realtimeUnavailable] : []
    }

    mutating func setOffline(_ offline: Bool, now: Date) -> [TripEvent] {
        guard session.isOffline != offline else { return [] }
        session.isOffline = offline
        refresh(now: now, fix: freshFix(at: now))
        return [offline ? .offline : .backOnline]
    }

    mutating func setLocationAuthorized(_ allowed: Bool, now: Date) {
        session.locationAuthorized = allowed
        refresh(now: now, fix: freshFix(at: now))
    }

    mutating func pause(now: Date) { guard !session.isFinished else { return }; session.status = .paused; session.lastUpdatedAt = now }
    mutating func resume(now: Date) { guard session.status == .paused else { return }; refresh(now: now, fix: freshFix(at: now)) }

    mutating func cancel(now: Date) -> [TripEvent] {
        guard !session.isFinished else { return [] }
        session.status = .cancelled; session.lastUpdatedAt = now
        return [.cancelled]
    }

    /// Continues the SAME trip on a new plan (after a reroute): new legs from the rider's position, same tripId and destination.
    mutating func replace(plan: TripPlan, origin: TripEndpoint, now: Date, reason: RerouteReason) -> [TripEvent] {
        session.plan = plan
        session.routeId = plan.routeId
        session.origin = origin
        session.currentLegIndex = 0
        session.legEnteredAt = now
        session.boardedAt = nil
        session.boardedWasInferred = false
        session.announced = []
        session.delayByLeg = [:]; session.etaByLeg = [:]; session.cancelledLegs = []
        session.reroutes += 1
        session.realtime = .notChecked
        mem = Memory(lastUsableFix: mem.lastUsableFix, prevFix: mem.prevFix)
        isOffRoute = false
        refresh(now: now, fix: freshFix(at: now))
        return [.rerouted(reason: reason)]
    }

    // MARK: Core evaluation

    private mutating func evaluate(now: Date, fix: TripFix?) -> [TripEvent] {
        guard !session.isFinished else { return [] }
        guard session.locationAuthorized else { refresh(now: now, fix: nil); return [] }   // never follow a rider we can't see
        guard session.status != .paused else { return [] }
        var events: [TripEvent] = []
        var hops = 0
        while hops <= session.plan.legs.count, let leg = session.currentLeg {
            hops += 1
            let moved = leg.kind.isVehicle ? stepVehicle(leg, now: now, fix: fix, events: &events) : stepSelfPropelled(leg, now: now, fix: fix, events: &events)
            if !moved || session.isFinished { break }
        }
        if !session.isFinished {
            checkOffRoute(now: now, fix: fix, events: &events)
            checkMissedDeparture(now: now, fix: fix, events: &events)
        }
        refresh(now: now, fix: fix ?? freshFix(at: now))
        return events
    }

    // MARK: Walking / cycling legs — followed by GPS

    private mutating func stepSelfPropelled(_ leg: TripLeg, now: Date, fix: TripFix?, events: inout [TripEvent]) -> Bool {
        // A bike leg starts with renting: nothing is "riding" until the rider has actually left the dock.
        if leg.kind == .bike, session.boardedAt == nil {
            if let fix, let from = leg.from, TripGeometry.distance(fix.coordinate, from) > 40 {
                session.boardedAt = now
                events.append(.boarded(legIndex: leg.index, inferred: false))
            } else { return false }
        }
        // An in-station interchange has no GPS underground: it runs on its real published minutes.
        if leg.kind == .walk, leg.walkKind == "MRT_TRANSFER_WALK" {
            let due = session.legEnteredAt.addingTimeInterval(TimeInterval(leg.durationSeconds) + 30)
            let contradicted = fix.flatMap { f in leg.to.map { TripGeometry.distance(f.coordinate, $0) > 300 } } ?? false
            if now >= due, !contradicted { return arrive(leg, now: now, inferred: true, events: &events) }
        }
        guard let fix, let target = leg.to else { return false }
        let distance = TripGeometry.distance(fix.coordinate, target)
        let approach = leg.kind == .bike ? TripPolicy.approachingBikeDistance : TripPolicy.approachingWalkDistance
        if distance <= approach, announce("approaching:\(leg.index)") {
            events.append(.approachingStop(legIndex: leg.index, name: leg.toName))
        }
        let radius = arrivalRadius(for: leg) + min(fix.accuracy / 2, TripPolicy.maxAccuracyAllowance)
        mem.arrivalStreak = distance <= radius ? mem.arrivalStreak + 1 : 0
        let confident = distance <= radius / 2 && fix.accuracy <= TripPolicy.confidentArrivalAccuracy
        if mem.arrivalStreak >= TripPolicy.arrivalConfirmations || confident {
            return arrive(leg, now: now, inferred: false, events: &events)
        }
        return false
    }

    // MARK: Vehicle legs — GPS when there is any, the timetable underground

    private mutating func stepVehicle(_ leg: TripLeg, now: Date, fix: TripFix?, events: inout [TripEvent]) -> Bool {
        if session.boardedAt == nil {
            var boarded = false, inferred = false
            if let fix, let from = leg.from {
                let away = TripGeometry.distance(fix.coordinate, from)
                if away > TripPolicy.boardedAwayDistance,
                   now >= leg.scheduledDeparture.addingTimeInterval(-120) || speed(of: fix) >= TripPolicy.boardedSpeed { boarded = true }
            } else if let last = mem.lastUsableFix, let from = leg.from,
                      now.timeIntervalSince(last.timestamp) >= TripPolicy.gpsLostSeconds,
                      TripGeometry.distance(last.coordinate, from) <= 200,
                      now >= estimatedDeparture(leg).addingTimeInterval(30) {
                boarded = true; inferred = true      // was at the stop, GPS vanished after departure time: on board (tunnel / platform)
            }
            guard boarded else { return false }
            session.boardedAt = now; session.boardedWasInferred = inferred
            mem.offRouteStreak = 0; mem.offRouteSince = nil
            events.append(.boarded(legIndex: leg.index, inferred: inferred))
        }
        guard let boardedAt = session.boardedAt else { return false }

        let ride = ridePlan(leg, boardedAt: boardedAt, now: now, fix: fix)
        if ride.shouldWarnAlight, announce("approaching:\(leg.index)") {
            events.append(.approachingStop(legIndex: leg.index, name: leg.toName))
            if let next = nextVehicleLeg(after: leg.index) {
                events.append(.transferRequired(fromLeg: leg.index, toLeg: next.index, name: next.lineLabel ?? next.toName))
                _ = announce("transfer:\(leg.index)")
            }
        }
        // Arrival by GPS: inside the station radius on consecutive fixes.
        if let fix, let to = leg.to {
            let d = TripGeometry.distance(fix.coordinate, to)
            let radius = arrivalRadius(for: leg) + min(fix.accuracy / 2, TripPolicy.maxAccuracyAllowance)
            mem.arrivalStreak = d <= radius ? mem.arrivalStreak + 1 : 0
            if mem.arrivalStreak >= TripPolicy.arrivalConfirmations || (d <= radius / 2 && fix.accuracy <= TripPolicy.confidentArrivalAccuracy) {
                return arrive(leg, now: now, inferred: false, events: &events)
            }
        }
        // Arrival by the clock (no GPS underground): only if GPS does not say the rider is still far away.
        if now >= ride.end.addingTimeInterval(TripPolicy.alightGraceSeconds) {
            let farByGPS = fix.flatMap { f in leg.to.map { TripGeometry.distance(f.coordinate, $0) > TripPolicy.scheduleAdvanceMaxDistance } } ?? false
            if !farByGPS { return arrive(leg, now: now, inferred: true, events: &events) }
        }
        return false
    }

    /// Where the rider is in the ride. GPS wins when there is a good fix; otherwise the timetable (and its delay).
    private func ridePlan(_ leg: TripLeg, boardedAt: Date, now: Date, fix: TripFix?) -> (fraction: Double, source: TripInfoSource, end: Date, secondsLeft: Double, stopsLeft: Int?, shouldWarnAlight: Bool, gpsDistanceToAlight: Double?) {
        let duration = TimeInterval(max(60, leg.durationSeconds))
        let end = max(estimatedArrival(leg), boardedAt.addingTimeInterval(duration))
        let timeFraction = clamp(now.timeIntervalSince(boardedAt) / max(1, end.timeIntervalSince(boardedAt)))
        var fraction = timeFraction, source: TripInfoSource = session.realtime == .live && session.delayByLeg[leg.index] != nil ? .realtime : .schedule
        var gpsDistance: Double?
        if let fix, let from = leg.from, let to = leg.to {
            let total = max(TripGeometry.distance(from, to), 1)
            let d = TripGeometry.distance(fix.coordinate, to)
            gpsDistance = d
            fraction = clamp(1 - d / total); source = .gps
        }
        let secondsLeft = source == .gps ? (1 - fraction) * duration : max(0, end.timeIntervalSince(now))
        let stopsLeft = leg.stopCount > 0 ? max(0, Int(ceil((1 - fraction) * Double(leg.stopCount) - 1e-9))) : nil
        let warn = secondsLeft <= TripPolicy.approachingVehicleSeconds
            || (gpsDistance.map { $0 <= TripPolicy.approachingVehicleDistance && leg.length > 1_500 } ?? false)
            || ((stopsLeft ?? 99) <= 1 && leg.stopCount >= 3 && fraction >= 0.5)
        return (fraction, source, end, secondsLeft, stopsLeft, warn, gpsDistance)
    }

    // MARK: Leg transitions

    private mutating func arrive(_ leg: TripLeg, now: Date, inferred: Bool, events: inout [TripEvent]) -> Bool {
        if leg.index == session.plan.legs.count - 1 {
            session.status = .arrived
            session.currentLegIndex = session.plan.legs.count
            events.append(.completed)
            return true
        }
        events.append(.arrivedAtStation(legIndex: leg.index, name: leg.toName, inferredFromSchedule: inferred))
        let next = leg.index + 1
        events.append(.legChanged(from: leg.index, to: next))
        session.currentLegIndex = next
        session.legEnteredAt = now
        session.boardedAt = nil; session.boardedWasInferred = false
        mem.arrivalStreak = 0; mem.offRouteStreak = 0; mem.offRouteSince = nil
        isOffRoute = false
        return true
    }

    // MARK: Off route / missed departure

    private mutating func checkOffRoute(now: Date, fix: TripFix?, events: inout [TripEvent]) {
        guard let fix, fix.accuracy <= 50, let leg = session.currentLeg, let to = leg.to else { return }
        let here = fix.coordinate
        var distance: Double?, threshold = 0.0
        switch leg.kind {
        case .walk:
            guard leg.walkKind == nil else { return }               // interchange/link walks are inside stations
            let start = previousEnd(of: leg) ?? leg.from
            guard let start else { return }
            distance = TripGeometry.distance(from: here, toSegment: start, to); threshold = TripPolicy.offRouteWalk
        case .bike:
            if session.boardedAt == nil, let from = leg.from { distance = TripGeometry.distance(here, from); threshold = TripPolicy.offRouteWaiting }
            else if let from = leg.from { distance = TripGeometry.distance(from: here, toSegment: from, to); threshold = TripPolicy.offRouteBike }
        default:
            guard let from = leg.from else { return }
            if session.boardedAt == nil {
                // Walked away from the boarding stop well before the vehicle is due.
                if now < leg.scheduledDeparture.addingTimeInterval(-120) { distance = TripGeometry.distance(here, from); threshold = TripPolicy.offRouteWaiting }
            } else {
                distance = TripGeometry.distance(from: here, toSegment: from, to)
                threshold = max(TripPolicy.offRouteVehicleFloor, leg.length * TripPolicy.offRouteVehicleFraction)
            }
        }
        guard let d = distance else { return }
        if d > threshold {
            mem.offRouteStreak += 1
            if mem.offRouteSince == nil { mem.offRouteSince = now }
            if mem.offRouteStreak >= TripPolicy.offRouteConfirmations,
               now.timeIntervalSince(mem.offRouteSince ?? now) >= TripPolicy.offRouteMinSeconds {
                isOffRoute = true
                if announce("offroute:\(leg.index)") { events.append(.offRoute(legIndex: leg.index, distanceMeters: d)) }
            }
        } else {
            mem.offRouteStreak = 0; mem.offRouteSince = nil
            if isOffRoute { isOffRoute = false; session.announced.remove("offroute:\(leg.index)") }
        }
    }

    /// A departure on a real timetable that the rider can no longer catch: still at the stop after it left, or (walking)
    /// that cannot be reached in time. Headway-based legs have no fixed departure, so they can never be "missed".
    private mutating func checkMissedDeparture(now: Date, fix: TripFix?, events: inout [TripEvent]) {
        guard let leg = session.currentLeg else { return }
        if leg.kind.isVehicle, leg.isTimetabled, session.boardedAt == nil {
            let limit = estimatedDeparture(leg).addingTimeInterval(TripPolicy.missedDepartureGrace)
            let atStop = fix.flatMap { f in leg.from.map { TripGeometry.distance(f.coordinate, $0) <= 300 } } ?? true
            if now > limit, atStop, announce("missed:\(leg.index)") { events.append(.missedDeparture(legIndex: leg.index)) }
        } else if leg.kind == .walk, let next = session.plan.legs[safe: leg.index + 1], next.kind.isVehicle, next.isTimetabled,
                  let fix, let to = leg.to {
            let walkSeconds = TripGeometry.distance(fix.coordinate, to) / 1.3
            if now.addingTimeInterval(walkSeconds) > estimatedDeparture(next).addingTimeInterval(60), announce("missed:\(next.index)") {
                events.append(.missedDeparture(legIndex: next.index))
            }
        }
    }

    // MARK: Derived state (status, instructions, remaining, progress)

    private mutating func refresh(now: Date, fix: TripFix?) {
        session.lastUpdatedAt = now
        guard !session.isFinished else {
            if session.status == .arrived {
                session.progress = 1; session.remainingDurationSeconds = 0; session.remainingDistanceMeters = 0
                session.current = TripInstruction(kind: .arrived, legIndex: session.plan.legs.count - 1, legKind: session.plan.legs.last?.kind ?? .walk, targetName: session.destination.name)
                session.nextAction = nil
            }
            return
        }
        guard let leg = session.currentLeg else { return }
        let legs = session.plan.legs
        if session.status != .paused { session.status = status(for: leg, legs: legs) }
        session.current = session.locationAuthorized ? instruction(for: leg, now: now, fix: fix) : TripInstruction(kind: .staticOverview, legIndex: leg.index, legKind: leg.kind, lineLabel: leg.lineLabel, targetName: leg.toName, time: leg.scheduledDeparture, source: .schedule)
        session.nextAction = legs[safe: leg.index + 1].map(preview)
        session.nextStop = leg.toName
        session.nextTransfer = nextTransfer(after: leg.index)

        let (remaining, distance) = remaining(now: now, fix: fix)
        session.remainingDurationSeconds = remaining
        session.remainingDistanceMeters = distance
        session.progress = clamp(1 - Double(remaining) / Double(session.plan.totalDurationSeconds))
    }

    private func status(for leg: TripLeg, legs: [TripLeg]) -> TripStatus {
        switch leg.kind {
        case .walk:
            let prevVehicle = legs[safe: leg.index - 1]?.kind.isVehicle == true
            let nextVehicle = legs[safe: leg.index + 1]?.kind.isVehicle == true
            if prevVehicle && nextVehicle { return .transferring }
            if legs.dropFirst(leg.index + 1).contains(where: { $0.kind.isVehicle }) { return .walkingToTransit }
            return .walkingToDestination
        case .bike:
            if session.boardedAt != nil { return .ridingBike }
            return legs.dropFirst(leg.index + 1).contains(where: { $0.kind.isVehicle }) ? .walkingToTransit : .walkingToDestination
        default:
            return session.boardedAt == nil ? .waitingForTransit : .onTransit
        }
    }

    private func instruction(for leg: TripLeg, now: Date, fix: TripFix?) -> TripInstruction {
        let delay = session.delayByLeg[leg.index]
        switch leg.kind {
        case .walk, .other:
            let distance = fix.flatMap { f in leg.to.map { TripGeometry.distance(f.coordinate, $0) } } ?? leg.length
            let approaching = fix != nil && distance <= TripPolicy.approachingWalkDistance
            let transferWalk = session.status == .transferring || leg.walkKind == "MRT_TRANSFER_WALK"
            return TripInstruction(
                kind: transferWalk && !approaching ? .transfer : (approaching ? .approaching : .walkTo), legIndex: leg.index, legKind: .walk,
                targetName: leg.toName, distanceMeters: distance,
                durationSeconds: fix != nil ? Int((distance / 1.3).rounded()) : leg.durationSeconds,
                source: fix != nil ? .gps : .estimate)
        case .bike:
            if session.boardedAt == nil {
                return TripInstruction(kind: .rentBike, legIndex: leg.index, legKind: .bike, lineLabel: leg.lineLabel, targetName: leg.fromName, source: .schedule)
            }
            let distance = fix.flatMap { f in leg.to.map { TripGeometry.distance(f.coordinate, $0) } } ?? leg.length
            let near = fix != nil && distance <= TripPolicy.approachingBikeDistance
            return TripInstruction(kind: near ? .returnBike : .rideBike, legIndex: leg.index, legKind: .bike, lineLabel: leg.lineLabel, targetName: leg.toName,
                                   distanceMeters: distance, durationSeconds: Int((distance / 4.0).rounded()), source: fix != nil ? .gps : .estimate)
        default:
            if let boardedAt = session.boardedAt {
                let ride = ridePlan(leg, boardedAt: boardedAt, now: now, fix: fix)
                var stopName: (String?, String?) = (nil, nil)
                if let names = leg.stopNames, names.count >= 2 {
                    let n = names.count - 1
                    let i = min(n, max(0, Int((ride.fraction * Double(n)).rounded(.down))))
                    stopName = (names[i], names[min(n, i + 1)])
                }
                return TripInstruction(
                    kind: ride.shouldWarnAlight ? .prepareToAlight : .rideVehicle, legIndex: leg.index, legKind: leg.kind, lineLabel: leg.lineLabel, towards: leg.towards,
                    targetName: leg.toName, distanceMeters: ride.gpsDistanceToAlight, durationSeconds: Int(ride.secondsLeft.rounded()),
                    stopsRemaining: ride.stopsLeft, stopsAreEstimated: true, currentStopName: stopName.0, nextStopName: stopName.1,
                    time: ride.end, delaySeconds: delay, source: ride.source)
            }
            let eta = session.etaByLeg[leg.index]
            let time = eta ?? estimatedDeparture(leg)
            return TripInstruction(
                kind: .waitForVehicle, legIndex: leg.index, legKind: leg.kind, lineLabel: leg.lineLabel, towards: leg.towards, targetName: leg.fromName,
                time: time, delaySeconds: delay,
                source: eta != nil || delay != nil ? .realtime : (leg.isTimetabled ? .schedule : .estimate))
        }
    }

    /// What is coming after the current step, as a preview (no live figures).
    private func preview(_ leg: TripLeg) -> TripInstruction {
        switch leg.kind {
        case .walk, .other: return TripInstruction(kind: leg.walkKind == "MRT_TRANSFER_WALK" ? .transfer : .walkTo, legIndex: leg.index, legKind: .walk, targetName: leg.toName, distanceMeters: leg.length, durationSeconds: leg.durationSeconds, source: .estimate)
        case .bike: return TripInstruction(kind: .rentBike, legIndex: leg.index, legKind: .bike, lineLabel: leg.lineLabel, targetName: leg.fromName, distanceMeters: leg.length, durationSeconds: leg.durationSeconds, source: .estimate)
        default:
            let delay = session.delayByLeg[leg.index]
            return TripInstruction(kind: .waitForVehicle, legIndex: leg.index, legKind: leg.kind, lineLabel: leg.lineLabel, towards: leg.towards, targetName: leg.fromName,
                                   time: session.etaByLeg[leg.index] ?? estimatedDeparture(leg), delaySeconds: delay,
                                   source: session.etaByLeg[leg.index] != nil || delay != nil ? .realtime : (leg.isTimetabled ? .schedule : .estimate))
        }
    }

    private func nextTransfer(after index: Int) -> TripTransfer? {
        let legs = session.plan.legs
        guard let j = legs.indices.first(where: { $0 > index && legs[$0].kind.isVehicle && legs[..<$0].contains(where: { $0.kind.isVehicle }) }) else { return nil }
        return TripTransfer(legIndex: j, lineLabel: legs[j].lineLabel, legKind: legs[j].kind, atName: legs[j].fromName)
    }

    private func nextVehicleLeg(after index: Int) -> TripLeg? {
        session.plan.legs.first { $0.index > index && $0.kind.isVehicle }
    }

    /// Time left and distance left, for the whole trip: this leg as far as it is known, then the legs still to come.
    private func remaining(now: Date, fix: TripFix?) -> (Int, Double) {
        let legs = session.plan.legs
        guard let leg = session.currentLeg else { return (0, 0) }
        var seconds = 0.0, meters = 0.0
        switch leg.kind {
        case .walk, .other, .bike:
            let d = fix.flatMap { f in leg.to.map { TripGeometry.distance(f.coordinate, $0) } } ?? leg.length
            let speed = leg.kind == .bike ? 4.0 : 1.3
            seconds = fix != nil ? d / speed : Double(leg.durationSeconds)
            meters = d
        default:
            if let b = session.boardedAt {
                let r = ridePlan(leg, boardedAt: b, now: now, fix: fix)
                seconds = r.secondsLeft; meters = r.gpsDistanceToAlight ?? leg.length * (1 - r.fraction)
            } else {
                seconds = max(0, estimatedDeparture(leg).timeIntervalSince(now)) + Double(leg.durationSeconds); meters = leg.length
            }
        }
        var previousArrival = leg.scheduledArrival
        for next in legs.dropFirst(leg.index + 1) {
            seconds += max(0, next.scheduledDeparture.timeIntervalSince(previousArrival)) + Double(next.durationSeconds)   // the planned wait, then the leg
            meters += next.length
            previousArrival = next.scheduledArrival
        }
        let laterDelay = Double(session.delayByLeg.filter { $0.key > leg.index }.map(\.value).max() ?? 0)
        return (Int((seconds + laterDelay).rounded()), meters)
    }

    // MARK: Helpers

    private func estimatedDeparture(_ leg: TripLeg) -> Date {
        if let eta = session.etaByLeg[leg.index] { return eta }
        return leg.scheduledDeparture.addingTimeInterval(TimeInterval(session.delayByLeg[leg.index] ?? 0))
    }
    private func estimatedArrival(_ leg: TripLeg) -> Date {
        leg.scheduledArrival.addingTimeInterval(TimeInterval(session.delayByLeg[leg.index] ?? 0))
    }
    private func previousEnd(of leg: TripLeg) -> TripCoordinate? { session.plan.legs[safe: leg.index - 1]?.to }

    private func arrivalRadius(for leg: TripLeg) -> Double {
        if leg.kind.isVehicle {
            switch leg.kind { case .tra, .hsr: return TripPolicy.bigStationRadius; case .metro: return TripPolicy.stationRadius; default: return TripPolicy.stopRadius }
        }
        guard let next = session.plan.legs[safe: leg.index + 1] else { return TripPolicy.destinationRadius }
        switch next.kind {
        case .tra, .hsr: return TripPolicy.bigStationRadius
        case .metro: return TripPolicy.stationRadius
        case .bus: return TripPolicy.stopRadius
        case .bike: return TripPolicy.dockRadius
        default: return TripPolicy.stopRadius
        }
    }

    private func speed(of fix: TripFix) -> Double {
        if fix.speed >= 0 { return fix.speed }
        guard let prev = mem.prevFix else { return 0 }
        let dt = fix.timestamp.timeIntervalSince(prev.timestamp)
        return dt > 0 ? TripGeometry.distance(prev.coordinate, fix.coordinate) / dt : 0
    }

    /// True the first time `key` is announced.
    private mutating func announce(_ key: String) -> Bool { session.announced.insert(key).inserted }
}

private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
