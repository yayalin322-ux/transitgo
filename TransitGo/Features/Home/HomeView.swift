import SwiftUI
import CoreLocation

/// One nearby bus stop (already merged across TDX name variants), with its live arrivals.
struct NearStopEntry: Identifiable {
    let stop: MergedStop
    let distance: CLLocationDistance
    var arrivals: [StopArrival] = []
    var id: String { stop.id }
}

@MainActor
@Observable
final class HomeViewModel {
    var nearStops: [NearStopEntry] = []
    var nearBikes: [BikeStationLive] = []
    var nearMetro: [MetroStationLive] = []
    var weather: WeatherInfo?
    var loading = false
    var error: String?

    private var weatherFetchedAt = Date.distantPast

    func reload(location: CLLocation, region: LocalRegion?) async {
        loading = nearStops.isEmpty && nearBikes.isEmpty
        defer { loading = false }
        error = nil

        if let city = region?.busCity {
            do {
                let raw: [NearbyStop] = try await TDXClient.shared.get(
                    "v2/Bus/Stop/City/\(city.rawValue)",
                    query: [
                        "$spatialFilter": "nearby(\(location.coordinate.latitude),\(location.coordinate.longitude),400)",
                        "$select": "StopUID,StopName,StopPosition,City",
                        "$top": "40",
                    ]
                )
                // Merge same-physical-stop name variants (see NearbyStopsView.MergedStop).
                var order: [String] = []
                var groups: [String: [NearbyStop]] = [:]
                for s in raw {
                    let key = normalizedStopName(s.stopName.display)
                    if groups[key] == nil { order.append(key) }
                    groups[key, default: []].append(s)
                }
                let merged = order.compactMap { key -> MergedStop? in
                    guard let items = groups[key] else { return nil }
                    let name = items.map(\.stopName.display).min(by: { $0.count < $1.count }) ?? key
                    return MergedStop(
                        stopUIDs: items.map(\.stopUID), displayName: name,
                        coordinate: items.first(where: { $0.coordinate != nil })?.coordinate
                    )
                }
                let top = merged.sorted { dist($0, location) < dist($1, location) }.prefix(3)
                var built: [NearStopEntry] = []
                for m in top {
                    let arrivals = (try? await BusService.shared.arrivals(city: city, stopUIDs: m.stopUIDs))?
                        .sorted { $0.sortKey < $1.sortKey } ?? []
                    built.append(NearStopEntry(stop: m, distance: dist(m, location), arrivals: arrivals))
                }
                nearStops = built
            } catch {
                self.error = error.localizedDescription
            }
        }

        if let bc = region?.bikeCity {
            var list = await BikeStationService.nearby(near: location.coordinate, radius: 700, city: bc) ?? []
            if list.isEmpty {
                list = (try? await BikeService.shared.nearbyLive(city: bc, near: location.coordinate)) ?? []
            }
            nearBikes = Array(list.sorted { $0.distance < $1.distance }.prefix(3))
        }

        if let op = region?.metroOperator {
            let stations = await MetroStationStore.shared.stations(operator: op)
            var withDist: [(MetroStation, CLLocationDistance)] = stations.compactMap { s in
                guard let c = s.coordinate else { return nil }
                return (s, CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location))
            }
            withDist = withDist.filter { $0.1 <= 500 }.sorted { $0.1 < $1.1 }
            var board: [MetroLiveBoard] = []
            if op.hasLiveBoard, !withDist.isEmpty {
                board = (try? await MetroService.shared.liveBoard(operator: op)) ?? []
            }
            let byStation = Dictionary(grouping: board, by: \.stationID)
            nearMetro = withDist.prefix(3).map { s, d in
                var live = MetroStationLive(station: s)
                live.distance = d
                live.next = (byStation[s.stationID] ?? []).sorted { ($0.estimateTime ?? 99) < ($1.estimateTime ?? 99) }
                return live
            }
        } else {
            nearMetro = []
        }

        if weather == nil || Date().timeIntervalSince(weatherFetchedAt) > 600 {
            weather = await WeatherService.current(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
            weatherFetchedAt = Date()
        }
    }

    private func dist(_ m: MergedStop, _ location: CLLocation) -> CLLocationDistance {
        guard let c = m.coordinate else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
    }
}

struct TripEditorTarget: Identifiable {
    let id = UUID()
    let existing: FavoriteTrip?
}

struct HomeView: View {
    @State private var location = LocationManager()
    @State private var resolver = RegionResolver.shared
    @State private var model = HomeViewModel()
    @State private var showBusSearch = false
    @State private var showSettings = false
    @State private var showFavorites = false
    @State private var showTransferPlanner = false
    @Environment(\.modelContext) private var modelContext
    /// A favorite trip that was tapped: opens the planner, which plans it again for right now.
    @State private var launchedTrip: FavoriteTrip?
    @State private var tripEditor: TripEditorTarget?
    @State private var needsLocationAlert = false
    @State private var tripCenter = TripNavigationCenter.shared

    @State private var path = NavigationPath()

    private var region: LocalRegion? { resolver.region }

    /// Tapping a favorite trip: count the use, then open the planner, which plans it again now.
    private func openFavorite(_ trip: FavoriteTrip) {
        if trip.spec.origin.isCurrentLocation, location.location == nil { needsLocationAlert = true; return }
        try? TripStore(context: modelContext).recordUse(trip)
        launchedTrip = trip
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                AnnouncementBanner(categories: ["bus", "rail", "metro"], includeRailAlerts: true)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                if let w = model.weather {
                    weatherRow(w)
                }

                if let resumable = tripCenter.resumable {
                    Section {
                        ResumeTripRow(session: resumable,
                                      onResume: { tripCenter.resume(city: region?.busCity, metroOperator: region?.metroOperator) },
                                      onDiscard: { tripCenter.discardResumable() })
                    }
                }

                FavoriteTripsSection(
                    onOpen: { trip in openFavorite(trip) },
                    onAdd: { tripEditor = TripEditorTarget(existing: nil) },
                    onEdit: { trip in tripEditor = TripEditorTarget(existing: trip) }
                )

                if location.location == nil {
                    Section {
                        ContentUnavailableView {
                            Label("開啟定位以顯示附近交通", systemImage: "location.slash")
                        } description: {
                            Text("首頁會顯示最近的公車站、即時到站與 YouBike。")
                        } actions: {
                            Button("開啟定位") { location.request() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    busSection
                    bikeSection
                    metroSection
                }
            }
            .navigationTitle(region?.areaName.isEmpty == false ? "\(region!.areaName)附近" : "附近")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if region?.busCity != nil {
                        Button { showTransferPlanner = true } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        }
                    }
                    Button { showFavorites = true } label: { Image(systemName: "star") }
                    Button { showBusSearch = true } label: { Image(systemName: "magnifyingglass") }
                }
            }
            .sheet(isPresented: $showBusSearch) {
                QuickRouteSearchView { route in
                    path.append(route)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showFavorites) {
                FavoritesView(onOpen: { item in
                    showFavorites = false
                    path.append(item)
                }, onOpenTrip: { trip in
                    showFavorites = false
                    // present after the sheet has gone
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openFavorite(trip) }
                })
            }
            .sheet(isPresented: $showTransferPlanner) {
                if let city = region?.busCity, let loc = location.location {
                    TransferPlannerView(city: city, origin: loc.coordinate, metroOperator: region?.metroOperator)
                }
            }
            .sheet(item: $launchedTrip) { trip in
                TransferPlannerView(
                    city: region?.busCity ?? .taipei,
                    origin: location.location?.coordinate ?? trip.spec.origin.coordinate,
                    metroOperator: region?.metroOperator,
                    initialTrip: trip.spec
                )
            }
            .sheet(item: $tripEditor) { target in
                FavoriteTripEditor(existing: target.existing, initial: nil,
                                   context: TripEditorContext(city: region?.busCity, near: location.location?.coordinate))
            }
            .fullScreenCover(isPresented: $tripCenter.isPresenting) {
                if let service = tripCenter.service { TripNavigationView(service: service, onClose: { tripCenter.closeScreen() }) }
            }
            .alert("需要目前位置", isPresented: $needsLocationAlert) {
                Button("好") {}
            } message: { Text("這個旅程從「目前位置」出發，請先開啟定位。") }
            .onAppear { location.request() }
            .task(id: taskKey) {
                guard let loc = location.location else { return }
                await resolver.resolve(for: loc)
                // Warm the local route catalog for this city so 🔍 searches are instant.
                if let city = resolver.region?.busCity {
                    await BusRouteCatalog.shared.ensureFresh(.city(city))
                }
                // Warm the YouBike map so opening it is instant.
                if let bc = resolver.region?.bikeCity {
                    _ = try? await BikeService.shared.cityAvailability(city: bc)
                }
                while !Task.isCancelled {
                    await model.reload(location: loc, region: resolver.region)
                    try? await Task.sleep(for: .seconds(20))
                }
            }
            .refreshable {
                if let loc = location.location { await model.reload(location: loc, region: resolver.region) }
            }
            .navigationDestination(for: MergedStop.self) { stop in
                if let c = region?.busCity {
                    NearbyStopDetailView(city: c, stopUIDs: stop.stopUIDs, displayName: stop.displayName)
                }
            }
            .navigationDestination(for: BikeStation.self) { station in
                if let c = region?.bikeCity { BikeStationDetailView(city: c, station: station) }
            }
            .navigationDestination(for: MetroStation.self) { station in
                if let op = region?.metroOperator {
                    MetroStationDetailView(operator: op, stationID: station.stationID, stationName: station.name)
                }
            }
            .navigationDestination(for: ScopedRoute.self) { r in
                BusRouteDetailView(scope: r.scope, route: r.route)
                    .onAppear { SearchHistoryStore.shared.record(scope: r.scope, route: r.route) }
            }
            .navigationDestination(for: FavoriteItem.self) { item in
                FavoriteDestination.view(for: item)
            }
        }
    }

    private var taskKey: String {
        guard let c = location.location?.coordinate else { return "none" }
        return "\(Int(c.latitude * 2000))-\(Int(c.longitude * 2000))"
    }

    private func weatherRow(_ w: WeatherInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: w.symbolName).font(.title3).foregroundStyle(.orange, .blue)
            Text("\(Int(w.tempC.rounded()))°").font(.headline.monospacedDigit())
            Text(w.description).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var busSection: some View {
        if !model.nearStops.isEmpty {
            Section("最近的公車站") {
                ForEach(model.nearStops) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        NavigationLink(value: entry.stop) {
                            HStack {
                                Label(entry.stop.displayName, systemImage: "bus.fill").font(.headline)
                                Spacer()
                                Text(distanceText(entry.distance)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if entry.arrivals.isEmpty {
                            Text("目前沒有到站動態").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(entry.arrivals.prefix(4)) { a in
                                HStack {
                                    Text(a.routeName).font(.subheadline.weight(.semibold))
                                    Text(a.direction == 0 ? "去程" : "返程")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(a.displayText)
                                        .font(.callout.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(etaColor(a))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else {
            Section("最近的公車站") {
                if model.loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Text(model.error ?? "附近查不到公車站")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var bikeSection: some View {
        if let bc = region?.bikeCity {
            Section("YouBike") {
                ForEach(model.nearBikes) { bike in
                    NavigationLink(value: bike.station) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(bike.station.name, systemImage: "bicycle").font(.headline)
                            }
                            Spacer()
                            if bike.distance < .greatestFiniteMagnitude {
                                Text(distanceText(bike.distance)).font(.caption).foregroundStyle(.secondary)
                            }
                            countCol("借", bike.rent, .green)
                            countCol("還", bike.ret, .blue)
                        }
                    }
                }
                NavigationLink {
                    BikeStationDetailView(city: bc, station: nil)
                } label: {
                    Label("打開 YouBike 地圖", systemImage: "map")
                }
            }
        }
    }

    @ViewBuilder
    private var metroSection: some View {
        if !model.nearMetro.isEmpty {
            Section("鄰近捷運") {
                ForEach(model.nearMetro) { item in
                    NavigationLink(value: item.station) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label(item.station.name, systemImage: "tram.fill").font(.headline)
                                Spacer()
                                Text(distanceText(item.distance)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let n = item.next.first {
                                Text("\(n.headingText)　\(n.etaText)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func countCol(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.callout.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 26)
    }

    private func distanceText(_ d: CLLocationDistance) -> String {
        d < 1000 ? "\(Int(d)) 公尺" : String(format: "%.1f 公里", d / 1000)
    }

    private func etaColor(_ a: StopArrival) -> Color {
        guard let t = a.estimateTime, (a.stopStatus ?? 0) == 0 else { return .secondary }
        if t < 120 { return .red }
        if t < 300 { return .orange }
        return .primary
    }
}
