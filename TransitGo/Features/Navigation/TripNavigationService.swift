import Foundation
import CoreLocation
import Network

// MARK: - Seams (real implementations below; tests substitute their own)

/// Where fixes come from. The real one is the app's existing `NavigationLocationTracker` — there is no second
/// location service. Permission is requested only when `start()` is called, i.e. when the user taps 開始導航.
@MainActor
protocol TripLocationSource: AnyObject {
    var authorization: CLAuthorizationStatus { get }
    var onFix: ((CLLocation) -> Void)? { get set }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
protocol TripReachability: AnyObject {
    var isOnline: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Persists the ONE active trip so a relaunch can resume it (a single transient record, not user data: a small
/// atomically-written file, independent of the SwiftData schema).
protocol TripSessionStoring {
    func save(_ session: TripSession)
    func load() -> TripSession?
    func clear()
}

struct TripBanner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isWarning: Bool
}

// MARK: - Service

/// Owns the live trip: takes location fixes, runs the engine, keeps realtime fresh, reroutes when (and only when)
/// the engine says the plan no longer fits, survives going offline, and can resume after the app is killed.
/// Views observe `session`/`banner`; they never see CLLocation, route matching, leg switching or arrival logic.
///
/// Performance contract: a location fix is `engine.ingest` (a handful of distance computations) — never a route
/// search, never a network call. Planning happens only on a reroute event (cooldown + rate limit + movement check);
/// realtime is polled on a timer (30 s) and on leg changes, through the shared cache/de-duplication.
@MainActor
@Observable
final class TripNavigationService {
    struct Dependencies {
        var location: TripLocationSource
        var reachability: TripReachability
        var store: TripSessionStoring
        var now: () -> Date = { Date() }
        /// Realtime for the route being followed (the app's `RealtimeTransitService`).
        var realtime: (MultimodalRoute) async -> RealtimeLookup = { await RealtimeTransitService.shared.getRealtime(route: $0) }
        /// Plans `spec` (origin = the rider's CURRENT position) for departure `now`.
        var planner: (TripSpec, CLLocationCoordinate2D, Date) async -> TripPlanOutcome
        /// Background timers (tick + realtime). Tests turn this off and drive time explicitly.
        var runsTimers = true
    }

    private(set) var session: TripSession?
    private(set) var events: [TripEvent] = []
    private(set) var banner: TripBanner?
    private(set) var isRerouting = false
    /// A reason the plan may no longer be good, waiting for the user's "重新規劃" (severe delay / cancelled).
    private(set) var suggestedReroute: RerouteReason?
    private(set) var plannerRequests = 0
    private(set) var realtimeRequests = 0

    private var engine: TripEngine?
    private let deps: Dependencies
    private var profile: TripProfile = .fastest
    private var timers: [Task<Void, Never>] = []
    private var lastPersistAt = Date.distantPast
    private var lastRerouteAt = Date.distantPast
    private var lastRerouteFrom: TripFix?
    private var recentReroutes: [Date] = []
    private var pendingReroute: RerouteReason?
    private var realtimeInFlight = false

    init(_ deps: Dependencies) {
        self.deps = deps
        deps.location.onFix = { [weak self] loc in self?.handle(fix: TripFix(loc)) }
        deps.location.onAuthorizationChange = { [weak self] status in self?.authorizationChanged(status) }
        deps.reachability.onChange = { [weak self] online in self?.connectivityChanged(online) }
    }

    var isActive: Bool { session.map { !$0.isFinished } ?? false }

    // MARK: Starting, recovering, ending

    /// Begins following `route`. Location permission is requested HERE (not at launch); if it is refused the trip is
    /// still shown as a static itinerary and never pretends to know where the rider is.
    func start(route: MultimodalRoute, origin: TripEndpoint, destination: TripEndpoint, profile: TripProfile = .fastest) {
        stopTimers()
        let now = deps.now()
        self.profile = profile
        let denied = [.denied, .restricted].contains(deps.location.authorization)
        var e = TripEngine(session: TripEngine.makeSession(plan: TripPlan(route: route), origin: origin, destination: destination, now: now, locationAuthorized: !denied))
        let started = e.begin(now: now)
        deps.reachability.start()
        _ = e.setOffline(!deps.reachability.isOnline, now: now)
        engine = e; session = e.session
        suggestedReroute = nil; pendingReroute = nil; recentReroutes = []
        banner = nil
        publish(started)
        if !denied { deps.location.start() }
        persist(force: true)
        startTimers()
        Task { await refreshRealtime() }
    }

    /// A trip that was in progress when the app was closed, if it is still worth resuming. Does not start anything.
    static func recoverableSession(store: TripSessionStoring, now: Date = Date()) -> TripSession? {
        guard let s = store.load(), !s.isFinished else { return nil }
        guard now.timeIntervalSince(s.lastUpdatedAt) < TripPolicy.staleAfterHours * 3600 else { store.clear(); return nil }
        return s
    }

    /// Resumes the stored trip exactly where it was (same leg, same phase) — the route is NOT planned again.
    @discardableResult
    func recover() -> Bool {
        guard let stored = Self.recoverableSession(store: deps.store, now: deps.now()) else { return false }
        stopTimers()
        var e = TripEngine(session: stored)
        let denied = [.denied, .restricted].contains(deps.location.authorization)
        e.setLocationAuthorized(!denied, now: deps.now())
        deps.reachability.start()
        _ = e.setOffline(!deps.reachability.isOnline, now: deps.now())
        engine = e
        session = e.session
        if !denied { deps.location.start() }
        startTimers()
        Task { await refreshRealtime() }
        return true
    }

    func cancel() {
        guard var e = engine else { return }
        publish(e.cancel(now: deps.now()))
        engine = e; session = e.session
        finish()
    }

    func pause() { guard var e = engine else { return }; e.pause(now: deps.now()); engine = e; session = e.session; persist(force: true) }
    func resume() { guard var e = engine else { return }; e.resume(now: deps.now()); engine = e; session = e.session; persist(force: true) }
    func dismissBanner() { banner = nil }
    func dismissSuggestion() { suggestedReroute = nil }

    // MARK: Inputs

    /// One real fix. Cheap: no planning, no network.
    func handle(fix: TripFix) {
        guard var e = engine, !(session?.isFinished ?? true) else { return }
        let events = e.ingest(fix, now: deps.now())
        engine = e; session = e.session
        publish(events)
        persist(force: !events.isEmpty)
        if e.session.isFinished { finish() }
    }

    /// Schedule-driven progress when no fix arrives (underground) and housekeeping for retries.
    func tick() {
        guard var e = engine, !(session?.isFinished ?? true) else { return }
        let events = e.tick(now: deps.now())
        engine = e; session = e.session
        publish(events)
        persist(force: !events.isEmpty)
        if e.session.isFinished { finish(); return }
        if let reason = pendingReroute, deps.reachability.isOnline { Task { await reroute(reason: reason, userRequested: false) } }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard var e = engine else { return }
        e.setLocationAuthorized(![.denied, .restricted].contains(status), now: deps.now())
        engine = e; session = e.session
    }

    private func connectivityChanged(_ online: Bool) {
        guard var e = engine else { return }
        publish(e.setOffline(!online, now: deps.now()))
        engine = e; session = e.session
        if online {
            Task { await refreshRealtime() }
            if let reason = pendingReroute { Task { await reroute(reason: reason, userRequested: false) } }
        }
    }

    // MARK: Realtime

    /// Asks the realtime service about the route being followed and hands the answer to the engine. One request at a
    /// time; skipped when offline (the timetable keeps guiding).
    func refreshRealtime() async {
        guard let route = engine?.session.plan.route, isActive, !realtimeInFlight else { return }
        guard deps.reachability.isOnline else {
            if var e = engine { publish(e.realtimeFailed(now: deps.now())); engine = e; session = e.session }
            return
        }
        realtimeInFlight = true
        realtimeRequests += 1
        let lookup = await deps.realtime(route)
        realtimeInFlight = false
        guard var e = engine, isActive else { return }
        switch lookup {
        case .loaded(let overlay): publish(e.apply(overlay: overlay, now: deps.now()))
        case .unavailable: publish(e.realtimeFailed(now: deps.now()))
        case .notRequested: break
        }
        engine = e; session = e.session
        persist(force: false)
    }

    // MARK: Rerouting

    /// The user pressed "重新規劃".
    func rerouteNow() { Task { await reroute(reason: suggestedReroute ?? .requestedByUser, userRequested: true) } }

    /// Plans again from the rider's CURRENT position to the same destination. Guarded: never while one is running,
    /// not within the cooldown, not without having moved (except a missed departure), never more than a few per
    /// 10 minutes, and not offline (it is retried when the connection returns). Never called per fix.
    func reroute(reason: RerouteReason, userRequested: Bool) async {
        guard var e = engine, isActive, !isRerouting else { return }
        let now = deps.now()
        guard let here = e.session.currentLocation, here.isUsable else {
            banner = TripBanner(text: "需要目前位置才能重新規劃", isWarning: true); return
        }
        guard deps.reachability.isOnline else { pendingReroute = reason; return }
        if !userRequested {
            recentReroutes.removeAll { now.timeIntervalSince($0) > 600 }
            if now.timeIntervalSince(lastRerouteAt) < TripPolicy.rerouteCooldownSeconds || recentReroutes.count >= TripPolicy.maxAutoReroutesPer10Min { pendingReroute = reason; return }
            if reason == .offRoute, let last = lastRerouteFrom,
               TripGeometry.distance(last.coordinate, here.coordinate) < TripPolicy.rerouteMinMovementMeters { pendingReroute = reason; return }
        }
        isRerouting = true; pendingReroute = nil; plannerRequests += 1
        lastRerouteAt = now; lastRerouteFrom = here; recentReroutes.append(now)
        banner = TripBanner(text: reason == .missedDeparture ? "已錯過此班次，正在尋找下一班…" : "正在重新規劃…", isWarning: true)

        let originHere = TripEndpoint(name: "目前位置", kind: .address, coordinate: here.coordinate.coordinate)
        let outcome = await deps.planner(TripSpec(origin: originHere, destination: e.session.destination, profile: profile), here.coordinate.coordinate, now)
        isRerouting = false
        guard var current = engine, isActive else { return }
        e = current
        switch outcome {
        case .routes(let result, let preferred):
            let route = result.multimodalRoutes.first { $0.id == preferred } ?? result.multimodalRoutes.first
            guard let route else { banner = TripBanner(text: "目前找不到可行路線，仍依原路線導航", isWarning: true); pendingReroute = nil; return }
            publish(e.replace(plan: TripPlan(route: route), origin: originHere, now: deps.now(), reason: reason))
            engine = e; session = e.session; suggestedReroute = nil
            persist(force: true)
            Task { await refreshRealtime() }
        default:
            current = e
            banner = TripBanner(text: (outcome.message ?? "目前找不到可行路線") + "，仍依原路線導航", isWarning: true)
        }
    }

    // MARK: Events

    private func publish(_ new: [TripEvent]) {
        guard !new.isEmpty else { return }
        events.append(contentsOf: new)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        guard let session else { return }
        for event in new {
            if event.isAlert, let text = TripInstructionText.banner(for: event, session: session) {
                banner = TripBanner(text: text, isWarning: { if case .delayed = event { return true }; if case .missedDeparture = event { return true }; return false }())
            }
            switch event {
            case .offRoute: Task { await reroute(reason: .offRoute, userRequested: false) }
            case .missedDeparture: Task { await reroute(reason: .missedDeparture, userRequested: false) }
            case .rerouteSuggested(let reason): suggestedReroute = reason
            case .legChanged: Task { await refreshRealtime() }
            default: break
            }
        }
    }

    // MARK: Persistence / timers

    private func persist(force: Bool) {
        guard let s = engine?.session, !s.isFinished else { return }
        let now = deps.now()
        guard force || now.timeIntervalSince(lastPersistAt) >= 15 else { return }
        lastPersistAt = now
        deps.store.save(s)
    }

    private func finish() {
        stopTimers()
        deps.location.stop(); deps.reachability.stop()
        deps.store.clear()          // a finished trip is not "in progress" any more
    }

    private func startTimers() {
        guard deps.runsTimers else { return }
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tick()
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TripPolicy.realtimeRefreshSeconds))
                await self?.refreshRealtime()
            }
        })
    }

    private func stopTimers() { timers.forEach { $0.cancel() }; timers = [] }
}

// MARK: - Real implementations

/// File-backed store for the single active trip (Application Support, atomic writes).
struct FileTripSessionStore: TripSessionStoring {
    let url: URL
    init(url: URL = FileTripSessionStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("active_trip.json")
    }
    func save(_ session: TripSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
    func load() -> TripSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TripSession.self, from: data)   // an unreadable/old file is simply "nothing to resume"
    }
    func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Adapts the app's existing continuous tracker.
@MainActor
final class TrackerLocationSource: TripLocationSource {
    private let tracker: NavigationLocationTracker
    var onFix: ((CLLocation) -> Void)? { get { tracker.onLocation } set { tracker.onLocation = newValue } }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get { tracker.onAuthorizationChange } set { tracker.onAuthorizationChange = newValue } }
    var authorization: CLAuthorizationStatus { tracker.authorization }
    init(tracker: NavigationLocationTracker? = nil) { self.tracker = tracker ?? NavigationLocationTracker() }
    func start() { tracker.start() }
    func stop() { tracker.stop() }
}

@MainActor
final class PathMonitorReachability: TripReachability {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    var onChange: ((Bool) -> Void)?
    private var started = false
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "trip.reachability"))
    }
    func stop() { monitor.cancel(); started = false }
}

extension TripNavigationService {
    /// The live wiring: the app's tracker, NWPathMonitor, the file store, the real realtime service and planner.
    static func live(city: BusCity?, metroOperator: MetroOperator?) -> TripNavigationService {
        TripNavigationService(Dependencies(
            location: TrackerLocationSource(), reachability: PathMonitorReachability(), store: FileTripSessionStore(),
            planner: { spec, here, now in await TripPlanner.plan(spec, city: city, metroOperator: metroOperator, currentLocation: here, now: now) }
        ))
    }
}
