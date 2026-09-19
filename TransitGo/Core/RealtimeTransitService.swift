import Foundation

// MARK: - Unified realtime model
//
// Realtime is a strictly OPTIONAL overlay on a route the static engine already found. Nothing
// here can change whether a route exists, and nothing overwrites the static timetable: the
// scheduled time and the realtime estimate always sit side by side. The app never talks to TDX
// for realtime — only to our backend (the TDX credential stays server-side).
//
// Wording is deliberately NOT in these types: `state` is an enum, and the Swift extensions at
// the bottom of this file are the one place that turns it into text/colour.

enum RealtimeState: String, Decodable {
    case normal, approaching, arriving, delayed, cancelled
    case notDeparted, notStopping, lastServicePassed, notOperating
    case unknown

    /// A state this build doesn't know (a newer backend) decodes to `.unknown`, never throws.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RealtimeState(rawValue: raw) ?? .unknown
    }
}

/// Where a shown time comes from. Never "realtime" unless a real estimate exists.
enum RealtimeEtaSource: String, Decodable {
    case realtime, scheduled, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RealtimeEtaSource(rawValue: raw) ?? .unknown
    }
}

/// Why realtime is missing. `.noData` / `.notSupported` are about the SOURCE; none of these
/// say anything about whether the planned route exists.
enum RealtimeFailureReason: String, Decodable {
    case timeout
    case rateLimited = "rate_limited"
    case credential
    case noData = "no_data"
    case unavailable
    case notSupported = "not_supported"
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RealtimeFailureReason(rawValue: raw) ?? .unavailable
    }
}

struct RealtimeStatus: Decodable {
    let mode: String
    let routeId: String?
    let tripId: String?
    let vehicleId: String?
    /// ISO-8601. nil when the source has no timetable (bus) — never a copy of the estimate.
    let scheduledTime: String?
    let estimatedTime: String?
    /// nil = the source has no delay figure (bus, metro), not "0".
    let delaySeconds: Int?
    let state: RealtimeState
    let source: String
    let updatedAt: String?
    // Source extras (present when the source has them).
    let routeName: String?
    let towards: String?
    let etaSeconds: Int?
    let stopsAway: Int?
    let direction: Int?
    let stopUID: String?
}

struct ServiceAlert: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let source: String
    let startTime: String?
    let endTime: String?
}

struct RealtimeLegOverlay: Decodable {
    let index: Int
    let mode: String
    let routeName: String?
    let available: Bool
    let reason: RealtimeFailureReason?
    let status: RealtimeStatus?
    let arrivals: [RealtimeStatus]
    let alerts: [ServiceAlert]
    let alertsAvailable: Bool
    let scheduledTime: String?
    let estimatedTime: String?
    let etaSource: RealtimeEtaSource
}

struct RealtimeRouteEta: Decodable {
    let etaSource: RealtimeEtaSource
    /// ISO-8601 — the static arrival shifted by the real delay. nil unless etaSource == .realtime.
    let estimatedArrivalTime: String?
    let shiftSeconds: Int?
    let basedOnLeg: Int?
}

struct RealtimeSummary: Decodable {
    let anyRealtime: Bool
    let state: RealtimeState?
    let delaySeconds: Int?
    let alerts: [ServiceAlert]
    let unavailableReasons: [RealtimeFailureReason]
}

struct RealtimeOverlay: Decodable {
    let generatedAt: String
    let legs: [RealtimeLegOverlay]
    let eta: RealtimeRouteEta
    let summary: RealtimeSummary

    var estimatedArrival: Date? {
        eta.estimatedArrivalTime.flatMap { RealtimeTime.parse($0) }
    }
}

/// What a caller gets for one route: loaded, or unavailable (with why). Never an error the UI
/// has to interpret as "no route".
enum RealtimeLookup {
    case notRequested
    case loaded(RealtimeOverlay)
    case unavailable(RealtimeFailureReason)

    var overlay: RealtimeOverlay? { if case .loaded(let o) = self { return o } else { return nil } }
}

/// Nearby-list result: next arrivals per requested stop UID.
struct RealtimeBusArrivals {
    let stops: [String: [RealtimeStatus]]
    let fetchedAt: Date
}

enum RealtimeTime {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }
}

// MARK: - The single entry point

/// The ONE place the app reads realtime transit information. ViewModels ask this actor; it asks
/// our backend (`/v1/realtime/*`), which owns the TDX credential, the caching and the
/// per-source failure handling. On top of that this actor keeps a short client-side cache and
/// shares an in-flight request between callers asking the same thing.
actor RealtimeTransitService {
    static let shared = RealtimeTransitService()

    /// Client cache lifetimes. Kept at the backend's shortest source TTL (bus ETA 15 s): a
    /// shorter client TTL could not show fresher data, only add requests.
    private let routeTTL: TimeInterval = 15
    private let failureTTL: TimeInterval = 10
    private let session: URLSession

    private struct Entry { let value: Any; let at: Date; let ttl: TimeInterval }
    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Any, Never>] = [:]
    /// Requests actually sent to the backend (for the performance report / tests).
    private(set) var networkRequests = 0

    init(session: URLSession = .shared) { self.session = session }

    // MARK: Route overlay

    /// Realtime for a route the static engine already planned. Always returns — `.unavailable`
    /// when the backend could not be reached or has nothing; the caller keeps showing the
    /// static route either way.
    func getRealtime(route: MultimodalRoute) async -> RealtimeLookup {
        // A walk-only route has nothing realtime to ask about.
        guard route.segments.contains(where: { $0.mode != "WALK" }) else { return .notRequested }
        let request = RealtimeRouteRequest(
            segments: route.segments.map(RealtimeSegmentRequest.init),
            departureTime: route.departureTime, arrivalTime: route.arrivalTime
        )
        let key = "route|" + route.segments.map { "\($0.mode)/\($0.from ?? "")/\($0.to ?? "")/\($0.tripId ?? "")/\($0.departureTime)" }.joined(separator: ";")
        return await shared(key: key, ttl: routeTTL, isFailure: { if case .unavailable = $0 { return true } else { return false } }) { [self] in
            await self.fetchRouteOverlay(request)
        }
    }

    private func fetchRouteOverlay(_ request: RealtimeRouteRequest) async -> RealtimeLookup {
        guard let base = BackendConfig.baseURL else { return .unavailable(.unavailable) }
        var req = URLRequest(url: base.appendingPathComponent("v1/realtime/route"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        networkRequests += 1
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(RealtimeRouteResponse.self, from: data)
            else { return .unavailable(.unavailable) }
            return .loaded(decoded.overlay)
        } catch {
            return .unavailable((error as? URLError)?.code == .timedOut ? .timeout : .unavailable)
        }
    }

    // MARK: Nearby stops

    /// Next bus arrivals at physical stop UIDs of one TDX scope ("City/Taipei" / "InterCity").
    /// Throws only when the backend can't answer — an empty list is a real "nothing to show".
    func busArrivals(scopePath: String, stopUIDs: [String]) async throws -> RealtimeBusArrivals {
        let uids = Array(Set(stopUIDs)).sorted()
        guard !uids.isEmpty else { return RealtimeBusArrivals(stops: [:], fetchedAt: Date()) }
        // The backend accepts at most 12 stops per call; merged stops are a handful.
        let batch = Array(uids.prefix(12))
        let key = "busStops|\(scopePath)|\(batch.joined(separator: ","))"
        let result = await shared(key: key, ttl: routeTTL, isFailure: { if case .failure = $0 { return true } else { return false } }) { [self] in
            await self.fetchBusArrivals(scopePath: scopePath, stopUIDs: batch)
        }
        return try result.get()
    }

    private func fetchBusArrivals(scopePath: String, stopUIDs: [String]) async -> Result<RealtimeBusArrivals, RealtimeFetchError> {
        guard let base = BackendConfig.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("v1/realtime/bus/stops"), resolvingAgainstBaseURL: false)
        else { return .failure(.unavailable) }
        comps.queryItems = [URLQueryItem(name: "scope", value: scopePath), URLQueryItem(name: "stops", value: stopUIDs.joined(separator: ","))]
        guard let url = comps.url else { return .failure(.unavailable) }
        networkRequests += 1
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(RealtimeBusStopsResponse.self, from: data)
            else { return .failure(.unavailable) }
            if !decoded.available, let reason = decoded.reason, reason != .noData { return .failure(.source(reason)) }
            return .success(RealtimeBusArrivals(stops: decoded.stops, fetchedAt: Date()))
        } catch {
            return .failure(.unavailable)
        }
    }

    // MARK: Cache + in-flight sharing

    /// Returns a fresh cached value, or joins the request already running for `key`, or starts
    /// one. Failures are cached briefly so a rate-limited/offline backend isn't hammered.
    private func shared<T: Sendable>(key: String, ttl: TimeInterval, isFailure: (T) -> Bool, load: @escaping @Sendable () async -> T) async -> T {
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < hit.ttl, let value = hit.value as? T { return value }
        if let running = inflight[key], let value = await running.value as? T { return value }
        let task = Task<Any, Never> { await load() }
        inflight[key] = task
        let value = await task.value
        inflight[key] = nil
        guard let typed = value as? T else { return await load() }
        cache[key] = Entry(value: typed, at: Date(), ttl: isFailure(typed) ? failureTTL : ttl)
        if cache.count > 64 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < $0.value.ttl } }
        return typed
    }

    /// Test/diagnostic hook.
    func resetForTesting() { cache = [:]; inflight = [:]; networkRequests = 0 }
}

enum RealtimeFetchError: Error {
    case unavailable
    case source(RealtimeFailureReason)
}

// MARK: - Wire types (private)

private struct RealtimeSegmentRequest: Encodable {
    let mode: String
    let routeId: String?
    let routeShortName: String?
    let scopePath: String?
    let line: String?
    let from: String?
    let to: String?
    let tripId: String?
    let departureTime: String
    let arrivalTime: String

    init(_ s: MultimodalSegment) {
        mode = s.mode; routeId = s.routeId; routeShortName = s.routeShortName; scopePath = s.scopePath
        line = s.line; from = s.from; to = s.to; tripId = s.tripId
        departureTime = s.departureTime; arrivalTime = s.arrivalTime
    }
}

private struct RealtimeRouteRequest: Encodable {
    let segments: [RealtimeSegmentRequest]
    let departureTime: String
    let arrivalTime: String
}

private struct RealtimeRouteResponse: Decodable {
    let generatedAt: String
    let legs: [RealtimeLegOverlay]
    let eta: RealtimeRouteEta
    let summary: RealtimeSummary
    var overlay: RealtimeOverlay { RealtimeOverlay(generatedAt: generatedAt, legs: legs, eta: eta, summary: summary) }
}

private struct RealtimeBusStopsResponse: Decodable {
    let available: Bool
    let reason: RealtimeFailureReason?
    let stops: [String: [RealtimeStatus]]
}

// MARK: - Presentation (the only place state -> wording/colour lives)

extension RealtimeState {
    /// Short badge for a route card. nil = say nothing (unknown must not be dressed up as "normal").
    var badge: (dot: String, text: String)? {
        switch self {
        case .normal, .approaching, .arriving: return ("🟢", "即時：正常")
        case .delayed: return ("🟠", "即時：延誤")
        case .cancelled: return ("🔴", "即時：停駛")
        case .notOperating: return ("🔴", "即時：今日未營運")
        case .lastServicePassed: return ("🔴", "即時：末班已過")
        case .notDeparted: return ("⚪️", "即時：尚未發車")
        case .notStopping: return ("🔴", "即時：交管不停靠")
        case .unknown: return nil
        }
    }
}

extension RealtimeFailureReason {
    /// Every failure reads as "realtime is missing" — never as "no route".
    var text: String {
        switch self {
        case .noData: return "目前沒有即時資料"
        case .notSupported: return "此運具沒有即時資料來源"
        default: return "即時資訊暫時無法取得"
        }
    }
}

extension RealtimeOverlay {
    /// One line for the route card, or nil if there is nothing honest to say.
    /// e.g. "🟠 即時：延誤 5 分" / "🟢 即時：正常" / "即時資訊暫時無法取得".
    var cardLine: String {
        guard summary.anyRealtime else {
            let reasons = summary.unavailableReasons
            return (reasons.count == 1 ? reasons[0] : .unavailable).text
        }
        guard let badge = summary.state?.badge else { return "即時資訊暫時無法取得" }
        var text = "\(badge.dot) \(badge.text)"
        if let d = summary.delaySeconds, d >= 60 { text += " \(Int((Double(d) / 60).rounded())) 分" }
        return text
    }

    /// True when the badge should read as a warning colour.
    var isWarning: Bool {
        guard summary.anyRealtime, let s = summary.state else { return false }
        return [.delayed, .cancelled, .notOperating, .lastServicePassed, .notStopping].contains(s)
    }
}
