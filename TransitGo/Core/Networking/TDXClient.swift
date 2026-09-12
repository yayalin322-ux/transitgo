import Foundation

/// Owns the shared URLSession, an in-memory response cache, in-flight de-duplication,
/// and adaptive request pacing. One 429 slows every caller down for a short cooldown
/// so the free-tier key stops getting hammered.
actor TDXCache {
    static let shared = TDXCache()

    private struct Entry { let data: Data; let expiry: Date }
    private var store: [String: Entry] = [:]
    private var inflight: [String: Task<Data, Error>] = [:]

    private var nextEarliest = Date.distantPast
    private var cooldownUntil = Date.distantPast
    /// Normal spacing ≈7 req/s; during a post-429 cooldown, ≈1.5 req/s.
    private var gap: TimeInterval { Date() < cooldownUntil ? 0.65 : 0.15 }

    var throttled: Bool { Date() < cooldownUntil }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 18
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func data(for request: URLRequest, ttl: TimeInterval) async throws -> Data {
        let key = request.url?.absoluteString ?? UUID().uuidString

        if let e = store[key], e.expiry > Date() { return e.data }
        if let running = inflight[key] { return try await running.value }

        let task = Task { () throws -> Data in
            defer { inflight[key] = nil }
            let data = try await fetch(request)
            if store.count > 400 { store = store.filter { $0.value.expiry > Date() } }
            store[key] = Entry(data: data, expiry: Date().addingTimeInterval(ttl))
            return data
        }
        inflight[key] = task
        return try await task.value
    }

    /// Serve stale-but-present data for `key` (used as a fallback when a refresh 429s).
    func stale(for request: URLRequest) -> Data? {
        store[request.url?.absoluteString ?? ""]?.data
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<2 {
            await waitTurn()
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch { throw TDXError.network }
            guard let h = response as? HTTPURLResponse else { throw TDXError.network }

            if h.statusCode == 429 || h.statusCode == 503 {
                enterCooldown()
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    continue
                }
                throw TDXError.http(status: h.statusCode, body: "rate limited")
            }
            guard (200..<300).contains(h.statusCode) else {
                if h.statusCode >= 500 {
                    Diagnostics.noteFailure(path: request.url?.path ?? "", kind: "tdx-http",
                                            detail: "HTTP \(h.statusCode)")
                }
                throw TDXError.http(status: h.statusCode,
                                    body: String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
        throw TDXError.http(status: 429, body: "rate limited")
    }

    private func waitTurn() async {
        let now = Date()
        let start = max(now, nextEarliest)
        nextEarliest = start.addingTimeInterval(gap)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    private func enterCooldown() {
        cooldownUntil = Date().addingTimeInterval(25)
        nextEarliest = max(nextEarliest, Date().addingTimeInterval(1.5))
    }
}

/// Thin async wrapper over the TDX "basic" REST API. Always requests JSON and attaches a bearer token.
struct TDXClient {
    static let shared = TDXClient()

    private let baseURL = URL(string: "https://tdx.transportdata.tw/api/basic")!

    /// - Parameters:
    ///   - path: e.g. `v2/Bus/EstimatedTimeOfArrival/City/Taipei/307`
    ///   - query: OData parameters, e.g. `["$filter": "...", "$top": "40"]`
    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "$format", value: "JSON"))
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        let token = try await TDXAuth.shared.validToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let data: Data
        do {
            data = try await TDXCache.shared.data(for: request, ttl: Self.ttl(for: path))
        } catch let error as TDXError {
            // On a rate-limit failure, fall back to the last good body if we have one.
            if case .http(let status, _) = error, status == 429 || status == 503,
               let cached = await TDXCache.shared.stale(for: request) {
                return try Self.decode(cached, path: path)
            }
            throw error
        }
        return try Self.decode(data, path: path)
    }

    private static func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Diagnostics.noteFailure(path: path, kind: "tdx-decode", detail: "\(error)")
            throw TDXError.decoding(error)
        }
    }

    /// How long a response for this path stays fresh in the cache.
    private static func ttl(for path: String) -> TimeInterval {
        let p = path.lowercased()
        if p.contains("estimatedtimeofarrival") || p.contains("realtime")
            || p.contains("liveboard") || p.contains("availability")
            || p.contains("availableseat") || p.contains("alert") || p.contains("news") {
            return 8
        }
        if p.contains("/route/") || p.contains("/shape/") || p.contains("/schedule/")
            || p.contains("/stopofroute/") || p.contains("/operator") || p.contains("/station")
            || p.contains("/vehicle/") || p.contains("odfare") || p.contains("dailytimetable")
            || p.contains("dailytraintimetable") || p.contains("stopofroute")
            || p.contains("/stop/") {
            return 1800
        }
        return 20
    }
}
