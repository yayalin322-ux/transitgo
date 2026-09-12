import SwiftUI

/// A stop name that matched the search keyword, with the routes serving it — lets the
/// search tab answer "what goes through 婦幼館?" as well as "where's route 307?".
struct StopRouteGroup: Identifiable {
    let displayName: String
    let city: BusCity
    let stopUIDs: [String]
    var routes: [ScopedRoute]
    var id: String { stopUIDs.first ?? displayName }
}

@MainActor
@Observable
final class BusSearchViewModel {
    /// nil = 全台灣 (search the priority scopes; "更多地區" expands to all).
    var regionFilter: BusScope?
    var keyword: String = ""
    var results: [ScopedRoute] = []
    var stopGroups: [StopRouteGroup] = []
    var isLoading = false
    var partial = false
    var expanded = false
    var errorText: String?

    private var searchTask: Task<Void, Never>?

    func search(expand: Bool = false) {
        searchTask?.cancel()
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        let regionFilter = regionFilter
        expanded = expand
        guard keyword.count >= 1 else {
            results = []
            stopGroups = []
            partial = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(expand ? 0 : 600))   // debounce
            if Task.isCancelled { return }
            isLoading = true
            errorText = nil
            defer { isLoading = false }
            let cityHint: BusCity? = {
                if case .city(let c) = regionFilter { return c }
                return RegionResolver.shared.region?.busCity
            }()
            async let routesTask = BusService.shared.searchAllRoutes(
                keyword: keyword, regionFilter: regionFilter, expanded: expand
            )
            async let stopsTask = Self.searchStops(keyword: keyword, city: cityHint)
            let (routes, partial) = await routesTask
            let stops = await stopsTask
            if !Task.isCancelled {
                results = routes
                self.partial = partial
                stopGroups = stops
            }
        }
    }

    /// Finds stops matching `keyword` in `city` (merging same-physical-stop name
    /// variants like "婦幼館"/"婦幼館站"), and the distinct routes serving each.
    static func searchStops(keyword: String, city: BusCity?) async -> [StopRouteGroup] {
        guard keyword.count >= 2, let city else { return [] }
        let escaped = keyword.replacingOccurrences(of: "'", with: "''")
        guard let raw: [NearbyStop] = try? await TDXClient.shared.get(
            "v2/Bus/Stop/City/\(city.rawValue)",
            query: [
                "$filter": "contains(StopName/Zh_tw,'\(escaped)')",
                "$select": "StopUID,StopName,StopPosition,City",
                "$top": "10",
            ]
        ), !raw.isEmpty else { return [] }

        var order: [String] = []
        var groups: [String: [NearbyStop]] = [:]
        for s in raw {
            let key = normalizedStopName(s.stopName.display)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }

        var out: [StopRouteGroup] = []
        for key in order.prefix(5) {   // a handful of matching stops is plenty
            guard let items = groups[key], !Task.isCancelled else { continue }
            let uids = items.map(\.stopUID)
            let name = items.map(\.stopName.display).min(by: { $0.count < $1.count }) ?? key
            guard let arrivals = try? await BusService.shared.arrivals(city: city, stopUIDs: uids),
                  !arrivals.isEmpty else { continue }
            var seen = Set<String>()
            let routes = arrivals
                .compactMap { a -> ScopedRoute? in
                    guard seen.insert(a.routeName).inserted else { return nil }
                    return ScopedRoute(scope: .city(city), route: BusRoute(
                        routeUID: a.routeName,
                        routeName: LocalizedName(zhTw: a.routeName, en: nil),
                        departureStopNameZh: nil, destinationStopNameZh: nil))
                }
                .sorted { natCompare($0.route.name, $1.route.name) }
            out.append(StopRouteGroup(displayName: name, city: city, stopUIDs: uids, routes: routes))
        }
        return out
    }
}

struct BusSearchView: View {
    @State private var model = BusSearchViewModel()
    @State private var history = SearchHistoryStore.shared
    @State private var showSettings = false

    private var keywordEmpty: Bool {
        model.keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                AnnouncementBanner(categories: ["bus"])
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                if keywordEmpty, !history.routes.isEmpty {
                    Section {
                        ForEach(history.routes) { item in
                            NavigationLink(value: ScopedRoute(
                                scope: item.scope,
                                route: BusRoute(routeUID: item.routeUID,
                                                routeName: LocalizedName(zhTw: item.name, en: nil),
                                                departureStopNameZh: nil,
                                                destinationStopNameZh: nil)
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name).font(.subheadline.weight(.semibold))
                                            Text(item.scope.displayName)
                                                .font(.caption2)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.tint.opacity(0.15), in: Capsule())
                                        }
                                        Text(item.endpoints)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { history.remove(item) } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("最近查詢")
                            Spacer()
                            Button("清除") { history.clear() }
                                .font(.caption)
                        }
                    }
                }

                if model.partial {
                    Label("部分地區查詢忙碌中，可稍後再試或改用行動網路", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(model.stopGroups) { group in
                    Section {
                        ForEach(group.routes) { item in
                            NavigationLink(value: item) {
                                HStack(spacing: 6) {
                                    Text(item.route.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Label("站點：\(group.displayName)", systemImage: "mappin.circle.fill")
                    }
                }
                ForEach(model.results) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.route.name).font(.headline)
                                Text(item.scope.displayName)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                            Text(item.route.endpointsText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.keyword.isEmpty, !model.isLoading, model.regionFilter == nil, !model.expanded {
                    Button {
                        model.search(expand: true)
                    } label: {
                        Label("沒看到？搜尋全部縣市", systemImage: "magnifyingglass")
                            .font(.footnote)
                    }
                }
                if model.results.isEmpty, model.stopGroups.isEmpty, !model.isLoading, !model.keyword.isEmpty {
                    if model.partial {
                        ContentUnavailableView("TDX 連線異常", systemImage: "wifi.exclamationmark",
                                               description: Text("運輸資料平台暫時無回應，請稍後再試，或改用行動網路"))
                    } else {
                        ContentUnavailableView("找不到路線", systemImage: "bus",
                                               description: Text("換個關鍵字，或用右上角篩選地區"))
                    }
                }
            }
            .navigationTitle("公車 / 客運")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("地區", selection: $model.regionFilter) {
                            Text("全台灣").tag(BusScope?.none)
                            ForEach(BusScope.all) { Text($0.displayName).tag(BusScope?.some($0)) }
                        }
                    } label: {
                        Label(model.regionFilter?.displayName ?? "全台灣",
                              systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $model.keyword, prompt: "路線號碼或站名，例如 307 或 婦幼館")
            .onChange(of: model.keyword) { _, _ in model.search() }
            .onChange(of: model.regionFilter) { _, _ in model.search() }
            .overlay { if model.isLoading { ProgressView() } }
            .navigationDestination(for: ScopedRoute.self) { item in
                BusRouteDetailView(scope: item.scope, route: item.route)
                    .onAppear { history.record(scope: item.scope, route: item.route) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
