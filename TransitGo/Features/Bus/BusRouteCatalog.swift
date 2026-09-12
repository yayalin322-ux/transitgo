import Foundation

/// On-device cache of the full route list per scope, so repeat searches resolve
/// instantly without hitting TDX. Populates itself the first time a scope is searched
/// and refreshes in the background when older than a week.
actor BusRouteCatalog {
    static let shared = BusRouteCatalog()

    private var mem: [String: [BusRoute]] = [:]
    private var loading: Set<String> = []
    private var buildQueue: [BusScope] = []
    private var draining = false

    private var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BusRouteCatalog", isDirectory: true)
    }
    private func fileURL(_ scope: BusScope) -> URL {
        dir.appendingPathComponent(scope.storageKey.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    /// Storage keys of every scope that already has a catalog on disk (or in memory).
    func builtScopeKeys() -> Set<String> {
        var keys = Set(mem.keys)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            keys.insert(f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: ":"))
        }
        return keys
    }

    /// Cached routes for a scope (memory → disk). `nil` = no catalog built yet.
    func cached(_ scope: BusScope) -> [BusRoute]? {
        if let m = mem[scope.storageKey] { return m }
        guard let data = try? Data(contentsOf: fileURL(scope)),
              let routes = try? JSONDecoder().decode([BusRoute].self, from: data) else { return nil }
        mem[scope.storageKey] = routes
        return routes
    }

    private func ageSeconds(_ scope: BusScope) -> TimeInterval? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: fileURL(scope).path),
              let date = attr[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// Local substring search over the cached list. `nil` if this scope has no catalog.
    func search(_ scope: BusScope, keyword: String) -> [BusRoute]? {
        guard let all = cached(scope) else { return nil }
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        let lk = k.lowercased()
        let hits = all.filter { $0.name.localizedCaseInsensitiveContains(k) }
        // Exact / prefix first so a short query like "1" still surfaces route 「1」.
        return hits.sorted { a, b in
            func r(_ n: String) -> Int { let x = n.lowercased(); return x == lk ? 0 : (x.hasPrefix(lk) ? 1 : 2) }
            let ra = r(a.name), rb = r(b.name)
            return ra != rb ? ra < rb : natCompare(a.name, b.name)
        }.prefix(60).map { $0 }
    }

    /// Fetch + persist the whole route list for a scope. Concurrent callers coalesce.
    @discardableResult
    func refresh(_ scope: BusScope) async -> [BusRoute]? {
        guard !loading.contains(scope.storageKey) else { return mem[scope.storageKey] }
        loading.insert(scope.storageKey)
        defer { loading.remove(scope.storageKey) }
        do {
            let routes: [BusRoute] = try await TDXClient.shared.get(
                "v2/Bus/Route/\(scope.pathComponent)",
                query: [
                    "$select": "RouteUID,RouteName,DepartureStopNameZh,DestinationStopNameZh",
                    "$top": "10000",
                ]
            )
            mem[scope.storageKey] = routes
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(routes) {
                try? data.write(to: fileURL(scope), options: .atomic)
            }
            return routes
        } catch {
            return nil
        }
    }

    /// Queue a background build/refresh if the catalog is missing or stale. Builds run
    /// one scope at a time, spaced out, so they never contend with live queries for the
    /// per-key rate limit.
    func ensureFresh(_ scope: BusScope, maxAge: TimeInterval = 7 * 86_400) {
        let stale = (ageSeconds(scope) ?? .greatestFiniteMagnitude) > maxAge
        guard cached(scope) == nil || stale else { return }
        guard !buildQueue.contains(where: { $0.storageKey == scope.storageKey }),
              !loading.contains(scope.storageKey) else { return }
        buildQueue.append(scope)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        // Let the initial search burst clear first.
        try? await Task.sleep(for: .seconds(4))
        while !buildQueue.isEmpty {
            let scope = buildQueue.removeFirst()
            await refresh(scope)
            try? await Task.sleep(for: .seconds(6))
        }
        draining = false
    }
}
