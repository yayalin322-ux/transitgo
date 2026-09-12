import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Full-screen YouBike map. Opens centred on `station` (if given) and pre-selects it,
/// otherwise on the user's location. The user can pan / zoom freely; tapping any pin
/// swaps the bottom card. `city` is only the *starting* scope — as the map pans, the
/// background sweep re-targets whichever TDX city (or two, near a border) is actually
/// under the map centre, so browsing keeps working across county lines, nationwide.
struct BikeStationDetailView: View {
    let city: BikeCity
    let station: BikeStation?

    @State private var searchText = ""
    @State private var searchResults: [(city: BikeCity, station: BikeStation)] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    @Environment(\.modelContext) private var context
    @Query private var favorites: [FavoriteItem]

    /// Every station we've ever seen this session, keyed by UID. Never shrinks below a cap.
    @State private var stationMap: [String: BikeStationLive] = [:]
    /// The subset actually drawn (nearest to the map centre) — keeps MapKit fast.
    @State private var rendered: [BikeStationLive] = []
    @State private var selectedUID: String?
    @State private var camera: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D
    /// Radius the background sweep is currently using; grows over time so coverage widens.
    @State private var sweepRadius = 900
    @State private var sweepPass = 0
    @State private var sweeping = false
    @State private var loading = true
    @State private var stale = false
    @State private var location = LocationManager()
    @State private var tracker = BikeTripTracker.shared
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private let renderCap = 320
    private let keepCap = 900

    init(city: BikeCity, station: BikeStation?) {
        self.city = city
        self.station = station
        let c = station?.coordinate ?? CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5319)
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
        _mapCenter = State(initialValue: c)
        _selectedUID = State(initialValue: station?.stationUID)
    }

    private var selected: BikeStationLive? {
        selectedUID.flatMap { stationMap[$0] }
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResultsList
                    .transition(.opacity)
            }
        }
        .searchable(text: $searchText, prompt: "搜尋全台 YouBike 站名，例如 婦幼館")
        .onChange(of: searchText) { _, newValue in runSearch(newValue) }
        .safeAreaInset(edge: .bottom) {
            if let s = selected, searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                StationCard(
                    live: s, now: now,
                    userLocation: location.location,
                    isFavorite: favorite(s) != nil,
                    isTracked: tracker.isTracking && tracker.trackedUID == s.station.stationUID,
                    canTrack: tracker.isActivitiesEnabled,
                    onNavigate: { openInMaps(s.station) },
                    onFavorite: { toggleFavorite(s) },
                    onTrackRent: { Task { await tracker.start(city: s.city, station: s.station, intent: "借車") } },
                    onTrackReturn: { Task { await tracker.start(city: s.city, station: s.station, intent: "還車") } },
                    onStopTrack: { Task { await tracker.stop() } }
                )
                .padding(12)
            }
        }
        .navigationTitle("YouBike")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await sweep(at: mapCenter, radius: max(sweepRadius, 2500)) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .onAppear {
            location.request()
            // Keep the process alive briefly in the background so the sweep loop below
            // keeps refreshing availability even while this screen isn't in the foreground.
            TripKeepAlive.shared.acquire()
        }
        .onDisappear {
            TripKeepAlive.shared.release()
        }
        .task {
            // 1. Instant: last snapshot from disk.
            if station == nil, let cached = BikeCache.load(city), !cached.live.isEmpty {
                merge(cached.live)
                mapCenter = cached.center
                camera = .region(MKCoordinateRegion(center: cached.center,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
                stale = cached.age > 60
            }
            // 2. Continuous sweep. Early passes are fast and grow the radius quickly so
            //    coverage fills in within a few seconds; later passes just refresh.
            let start = station?.coordinate ?? location.location?.coordinate ?? mapCenter
            sweepRadius = 1200
            sweepPass = 0
            await sweep(at: start, radius: sweepRadius, seedSelection: true)
            while !Task.isCancelled {
                let expanding = sweepRadius < 8000
                let wait: Double = expanding ? 3 : 12
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { break }
                sweepPass += 1
                if expanding { sweepRadius = min(sweepRadius + 1600, 9000) }
                // Once wide, keep centring the refresh on where the user is looking —
                // this is also what lets panning into a new county pick up its stations.
                await sweep(at: mapCenter, radius: expanding ? sweepRadius : 3000)
            }
        }
    }

    private var map: some View {
        Map(position: $camera, selection: $selectedUID) {
            UserAnnotation()
            ForEach(rendered) { s in
                if let c = s.station.coordinate {
                    Annotation(s.station.name, coordinate: c) {
                        BikePin(rent: s.rent,
                                highlighted: s.station.stationUID == selectedUID,
                                offline: !(s.availability?.inService ?? true))
                    }
                    .tag(s.station.stationUID)
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
        .onMapCameraChange(frequency: .onEnd) { ctx in
            mapCenter = ctx.region.center
            recomputeRendered()
            // Fetch the newly-visible area, but don't stack requests.
            if !sweeping {
                Task { await sweep(at: ctx.region.center, radius: 2500) }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if stale {
                    Text("顯示上次資料，更新中…")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                } else if !stationMap.isEmpty {
                    Text("\(stationMap.count) 站・持續擴大範圍")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.top, 6)
        }
        .overlay {
            if stationMap.isEmpty {
                ContentUnavailableView {
                    Label(loading ? "載入附近站點…" : "這附近沒有 YouBike 站",
                          systemImage: loading ? "bicycle" : "bicycle.circle")
                } description: {
                    if loading { ProgressView().padding(.top, 4) }
                    else { Text("拖動地圖到別的區域").font(.footnote) }
                }
                .background(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        List {
            if searching {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(searchResults, id: \.station.stationUID) { item in
                Button {
                    selectSearchResult(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bicycle").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.station.name).font(.subheadline.weight(.semibold))
                            Text(item.city.displayName).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }
            if searchResults.isEmpty, !searching {
                Text("找不到「\(searchText)」").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
    }

    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { searchResults = []; searching = false; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            searching = true
            var results = await SharedBikeService.search(keyword: keyword) ?? []
            if results.isEmpty {
                let local = await BikeStationCatalog.shared.search(keyword)
                results = local.prefix(30).map { BikeStationLive(station: $0.station, city: $0.city) }
            }
            if !Task.isCancelled {
                searchResults = Array(results.prefix(30)).map { (city: $0.city, station: $0.station) }
                searching = false
            }
        }
    }

    private func selectSearchResult(_ item: (city: BikeCity, station: BikeStation)) {
        searchText = ""
        searchResults = []
        guard let c = item.station.coordinate else { return }
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))
        mapCenter = c
        selectedUID = item.station.stationUID
        Task {
            let avail = try? await BikeService.shared.availability(city: item.city, stationUID: item.station.stationUID)
            var entry = BikeStationLive(station: item.station, availability: avail, city: item.city)
            entry.distance = 0
            merge([entry])
            await sweep(at: c, radius: 1200)
        }
    }

    /// Fetch one area and fold the results into `stationMap` (add + update, never remove).
    /// Merge is atomic on the main actor — a cancelled `.task` never leaves a half-merge.
    private func sweep(at center: CLLocationCoordinate2D, radius: Int, seedSelection: Bool = false) async {
        sweeping = true
        defer { sweeping = false }
        var fresh = await SharedBikeService.nearby(near: center, radius: radius, city: nil) ?? []
        if fresh.isEmpty {
            let cities = BikeCity.nearest(to: center, count: 2)
            fresh = await BikeService.shared.nearbyLive(cities: cities, near: center, radius: min(radius, 3000))
        }
        loading = false
        guard !fresh.isEmpty, !Task.isCancelled else { return }
        stale = false
        merge(fresh)
        BikeCache.saveGrouped(Array(stationMap.values), center: mapCenter)
        if seedSelection, selected == nil {
            selectedUID = rendered.first?.station.stationUID
        }
    }

    private func merge(_ fresh: [BikeStationLive]) {
        for s in fresh { stationMap[s.station.stationUID] = s }
        // Trim to the nearest `keepCap` to the current map centre.
        if stationMap.count > keepCap {
            let c = CLLocation(latitude: mapCenter.latitude, longitude: mapCenter.longitude)
            let kept = stationMap.values
                .sorted { dist($0, c) < dist($1, c) }
                .prefix(keepCap)
            stationMap = Dictionary(uniqueKeysWithValues: kept.map { ($0.station.stationUID, $0) })
        }
        recomputeRendered()
    }

    private func recomputeRendered() {
        let c = CLLocation(latitude: mapCenter.latitude, longitude: mapCenter.longitude)
        rendered = stationMap.values
            .sorted { dist($0, c) < dist($1, c) }
            .prefix(renderCap)
            .map { $0 }
    }

    private func dist(_ s: BikeStationLive, _ from: CLLocation) -> CLLocationDistance {
        guard let cc = s.station.coordinate else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: cc.latitude, longitude: cc.longitude).distance(from: from)
    }

    private func favorite(_ s: BikeStationLive) -> FavoriteItem? {
        favorites.first {
            $0.kind == FavoriteKind.bikeStation.rawValue && $0.routeName == s.station.stationUID
        }
    }

    private func openInMaps(_ s: BikeStation) {
        guard let c = s.coordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = s.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func toggleFavorite(_ live: BikeStationLive) {
        let s = live.station
        if let fav = favorites.first(where: {
            $0.kind == FavoriteKind.bikeStation.rawValue && $0.routeName == s.stationUID
        }) {
            context.delete(fav)
        } else {
            context.insert(FavoriteItem(
                kind: FavoriteKind.bikeStation.rawValue,
                city: live.city.rawValue,
                routeName: s.stationUID,
                title: s.name,
                subtitle: s.stationAddress?.display ?? "",
                lat: s.coordinate?.latitude ?? 0,
                lon: s.coordinate?.longitude ?? 0
            ))
        }
    }
}

// MARK: - Bottom card

private struct StationCard: View {
    let live: BikeStationLive
    let now: Date
    let userLocation: CLLocation?
    let isFavorite: Bool
    let isTracked: Bool
    let canTrack: Bool
    let onNavigate: () -> Void
    let onFavorite: () -> Void
    let onTrackRent: () -> Void
    let onTrackReturn: () -> Void
    let onStopTrack: () -> Void

    private var a: BikeAvailability? { live.availability }

    private var distanceText: String? {
        guard let here = userLocation, let c = live.station.coordinate else { return nil }
        let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
        return d < 1000 ? "\(Int(d)) 公尺" : String(format: "%.1f 公里", d / 1000)
    }
    private var updatedText: String? {
        guard let u = a?.updatedAt else { return nil }
        let s = Int(now.timeIntervalSince(u))
        if s < 60 { return "\(max(1, s)) 秒前更新" }
        if s < 3600 { return "\(s / 60) 分前更新" }
        return "資料較舊"
    }
    private var statusColor: Color {
        guard let a else { return .gray }
        if !a.inService { return .orange }
        if (a.availableRentBikes ?? 0) == 0 || (a.availableReturnBikes ?? 0) == 0 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)

            Text(live.station.name).font(.title3.bold())

            HStack(spacing: 14) {
                if let d = distanceText { Label(d, systemImage: "figure.walk").font(.subheadline) }
                if let u = updatedText { Label(u, systemImage: "arrow.triangle.2.circlepath").font(.subheadline) }
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                bigCount("可借", a?.availableRentBikes ?? 0, .green, "bicycle")
                Divider().frame(height: 42)
                bigCount("可停", a?.availableReturnBikes ?? 0, .blue, "parkingsign")
                if let g = a?.availableRentBikesDetail?.generalBikes,
                   let e = a?.availableRentBikesDetail?.electricBikes {
                    Divider().frame(height: 42)
                    VStack(spacing: 2) {
                        Text("\(g)/\(e)").font(.headline.monospacedDigit())
                        Text("一般/電動").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(a?.statusText ?? "查詢中…").font(.subheadline.weight(.medium))
                Spacer()
                if let addr = live.station.stationAddress?.display, !addr.isEmpty {
                    Text(addr).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button(action: onNavigate) {
                    Label("導航", systemImage: "location.fill").frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onFavorite) {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
                        .frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.bordered)
            }

            if isTracked {
                Button(role: .destructive, action: onStopTrack) {
                    Label("停止追蹤", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    Button(action: onTrackRent) {
                        Label("追蹤借車", systemImage: "bicycle").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(!canTrack)
                    Button(action: onTrackReturn) {
                        Label("追蹤還車", systemImage: "parkingsign").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(!canTrack)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 8, y: 2)
    }

    private func bigCount(_ label: String, _ value: Int, _ color: Color, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
            Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pin

private struct BikePin: View {
    let rent: Int
    let highlighted: Bool
    var offline: Bool = false

    private var color: Color { offline ? .gray : (rent == 0 ? .orange : .green) }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(rent)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: highlighted ? 32 : 26, minHeight: highlighted ? 32 : 26)
                .background(color, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: highlighted ? 3 : 1.5))
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: highlighted ? 11 : 9))
                .foregroundStyle(color)
                .offset(y: -3)
        }
        .shadow(radius: highlighted ? 4 : 1)
    }
}
