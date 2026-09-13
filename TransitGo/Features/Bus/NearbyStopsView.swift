import SwiftUI
import MapKit
import CoreLocation

struct NearbyStop: Codable, Identifiable, Hashable {
    let stopUID: String
    let stopName: LocalizedName
    let stopPosition: GeoPoint?
    let city: String?

    var id: String { stopUID }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = stopPosition?.lat, let lon = stopPosition?.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case stopUID = "StopUID"
        case stopName = "StopName"
        case stopPosition = "StopPosition"
        case city = "City"
    }
}

enum NearbyMode: String, CaseIterable, Identifiable {
    case bus, bike, metro, landmark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bus: return "公車"
        case .bike: return "YouBike"
        case .metro: return "捷運"
        case .landmark: return "地標"
        }
    }
    var icon: String {
        switch self {
        case .bus: return "bus.fill"
        case .bike: return "bicycle"
        case .metro: return "tram.fill"
        case .landmark: return "mappin.circle.fill"
        }
    }
}

struct NearbyLandmark: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D
    var distance: CLLocationDistance = 0
    var category: LandmarkCategory = .other
}

/// Real nearby points of interest (Apple's own POI index, via the dedicated
/// `MKLocalPointsOfInterestRequest` API — no arbitrary search keyword needed, unlike
/// `MKLocalSearch`) — tapping one opens PlaceDetailView so the user can read/write real
/// reviews for it, same as landmarks found through the transfer planner's search.
@MainActor
@Observable
final class LandmarkNearbyViewModel {
    var items: [NearbyLandmark] = []
    var isLoading = false
    var errorText: String?

    func load(near location: CLLocation) async {
        isLoading = items.isEmpty
        errorText = nil
        defer { isLoading = false }
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 800)
        async let appleTask: [NearbyLandmark] = {
            guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
            return response.mapItems.compactMap { item -> NearbyLandmark? in
                guard let name = item.name else { return nil }
                let c = item.placemark.coordinate
                let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
                return NearbyLandmark(name: name, subtitle: item.placemark.title, coordinate: c, distance: d,
                                       category: LandmarkCategory(appleCategory: item.pointOfInterestCategory))
            }
        }()
        // Our own users' real submitted landmarks (admin-approved only) — merged in
        // alongside Apple's POI index, e.g. a small local spot Apple doesn't have.
        async let ownTask: [NearbyLandmark] = {
            let own = await UserLandmarkService.nearby(location.coordinate, radiusMeters: 800)
            return own.map {
                NearbyLandmark(name: $0.name, subtitle: $0.description.isEmpty ? "使用者新增地標" : $0.description,
                               coordinate: $0.coordinate,
                               distance: CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: location),
                               category: $0.category)
            }
        }()
        let (apple, own) = await (appleTask, ownTask)
        items = (apple + own).sorted { $0.distance < $1.distance }
    }

    /// Keyword search (unlike `load`, which only browses Apple's POI index by radius) —
    /// same idea as the transfer planner's landmark search, scoped to a wider region so
    /// searching by name can find something further than the passive-browse radius.
    func search(_ keyword: String, near location: CLLocation) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start() else {
            errorText = "搜尋時發生錯誤"
            return
        }
        items = response.mapItems.compactMap { item -> NearbyLandmark? in
            guard let name = item.name else { return nil }
            let c = item.placemark.coordinate
            let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
            return NearbyLandmark(name: name, subtitle: item.placemark.title, coordinate: c, distance: d,
                                   category: LandmarkCategory(appleCategory: item.pointOfInterestCategory))
        }.sorted { $0.distance < $1.distance }
    }
}

// MARK: - Per-mode view models

/// A bus stop for display, after folding together TDX entries that are really the same
/// physical stop but registered under slightly different names (e.g. "婦幼館" from one
/// bus company and "婦幼館站" from another) — merged if their normalized names match
/// AND they're within the same small nearby-search radius.
struct MergedStop: Identifiable, Hashable {
    let stopUIDs: [String]
    let displayName: String
    let coordinate: CLLocationCoordinate2D?
    var id: String { stopUIDs.first ?? displayName }

    static func == (l: MergedStop, r: MergedStop) -> Bool { l.stopUIDs == r.stopUIDs }
    func hash(into hasher: inout Hasher) { hasher.combine(stopUIDs) }
}

/// Strips a bare trailing "站" so "婦幼館" and "婦幼館站" compare equal — the two most
/// common TDX naming variants for the same physical stop.
func normalizedStopName(_ name: String) -> String {
    name.hasSuffix("站") && name.count > 2 ? String(name.dropLast()) : name
}

@MainActor
@Observable
final class NearbyViewModel {
    var stops: [MergedStop] = []
    var isLoading = false
    var errorText: String?

    func load(near location: CLLocation, city: BusCity) async {
        isLoading = stops.isEmpty
        errorText = nil
        defer { isLoading = false }
        let (lat, lon) = (location.coordinate.latitude, location.coordinate.longitude)
        do {
            let result: [NearbyStop] = try await TDXClient.shared.get(
                "v2/Bus/Stop/City/\(city.rawValue)",
                query: [
                    "$spatialFilter": "nearby(\(lat),\(lon),500)",
                    "$select": "StopUID,StopName,StopPosition,City",
                    "$top": "80",
                ]
            )
            // Group by normalized name — the 500m radius is small enough that two
            // entries sharing a name are almost always the same physical stop.
            var order: [String] = []
            var groups: [String: [NearbyStop]] = [:]
            for s in result {
                let key = normalizedStopName(s.stopName.display)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(s)
            }
            let byName = order.compactMap { key -> MergedStop? in
                guard let items = groups[key] else { return nil }
                let name = items.map(\.stopName.display).min(by: { $0.count < $1.count }) ?? key
                return MergedStop(
                    stopUIDs: items.map(\.stopUID),
                    displayName: name,
                    coordinate: items.first(where: { $0.coordinate != nil })?.coordinate
                )
            }
            // Second pass: fold together any *different*-named entries that sit within a
            // few metres of each other — two stop poles that close are, in practice,
            // always the same physical stop, whatever each bus company called it.
            stops = Self.mergeByProximity(byName)
                .sorted { distance($0, location) < distance($1, location) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func mergeByProximity(_ input: [MergedStop], threshold: CLLocationDistance = 40) -> [MergedStop] {
        var clusters: [MergedStop] = []
        for stop in input {
            guard let c = stop.coordinate else { clusters.append(stop); continue }
            let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
            if let i = clusters.firstIndex(where: { existing in
                guard let ec = existing.coordinate else { return false }
                return CLLocation(latitude: ec.latitude, longitude: ec.longitude).distance(from: here) < threshold
            }) {
                let existing = clusters[i]
                let name = [existing.displayName, stop.displayName].min(by: { $0.count < $1.count })!
                clusters[i] = MergedStop(
                    stopUIDs: existing.stopUIDs + stop.stopUIDs,
                    displayName: name,
                    coordinate: existing.coordinate
                )
            } else {
                clusters.append(stop)
            }
        }
        return clusters
    }

    func distance(_ stop: MergedStop, _ location: CLLocation) -> CLLocationDistance {
        guard let c = stop.coordinate else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
    }
}

@MainActor
@Observable
final class BikeNearbyViewModel {
    var items: [BikeStationLive] = []
    var isLoading = false
    var errorText: String?

    /// Wide enough that the map has something worth clustering, not just the handful of
    /// stations right on top of you. Shared-backend cache first (no TDX, no rate limit);
    /// TDX only as a fallback.
    func load(near location: CLLocation, city: BikeCity) async {
        isLoading = items.isEmpty
        errorText = nil
        defer { isLoading = false }
        if let shared = await SharedBikeService.nearby(near: location.coordinate, radius: 3000, city: nil), !shared.isEmpty {
            items = shared
            return
        }
        do {
            items = try await BikeService.shared.nearbyLive(city: city, near: location.coordinate, radius: 3000)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// A group of nearby YouBike stations shown as one bubble when the map is zoomed out too
/// far to tell individual stations apart — same idea as the marker clustering common in
/// map apps, done manually since SwiftUI's `Map` doesn't cluster `Marker`/`Annotation`
/// automatically the way UIKit's `MKMapView` does.
struct BikeCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let stations: [BikeStationLive]
    var stationCount: Int { stations.count }
    var totalRent: Int { stations.reduce(0) { $0 + $1.rent } }
    var isSingle: Bool { stations.count == 1 }
    /// Whether to bubble is about visual clutter — how many separate pins would overlap —
    /// not how many bikes are sitting in them. A single big station with 80 bikes is still
    /// just one real station and should show as one real pin, not a "80+" badge; only
    /// collapse once there are genuinely several distinct stations crowded together.
    var shouldBubble: Bool { stationCount > 6 }

    /// Tiered like a typical bike-share map: exact count while small, rounded-down bucket
    /// once there's enough in one spot that an exact number isn't actually useful. Once
    /// past 100 it steps in hundreds, capped at 900+ so the label never grows unbounded.
    var badgeText: String {
        switch totalRent {
        case 0..<10: return "\(totalRent)"
        case 10..<50: return "10+"
        case 50..<100: return "50+"
        case 900...: return "900+"
        default: return "\((totalRent / 100) * 100)+"
        }
    }
    var badgeColor: Color {
        switch totalRent {
        case 0..<10: return .gray
        case 10..<50: return .blue
        case 50..<200: return .green
        case 200..<500: return .orange
        default: return .red
        }
    }
}

/// Buckets stations into a grid sized relative to the current visible map span — zoom out
/// and cells cover more ground (fewer, bigger clusters); zoom in and cells shrink until
/// each one is just a single real station again.
func clusterBikeStations(_ items: [BikeStationLive], span: MKCoordinateSpan) -> [BikeCluster] {
    // YouBike stations in a dense city grid often sit only 200-400m apart — the divisor
    // and floor both need to be generous enough that stations actually group at a normal
    // "nearby" zoom level, not just once you've zoomed most of the way out.
    let cellLat = max(span.latitudeDelta / 3, 0.008)
    let cellLon = max(span.longitudeDelta / 3, 0.008)
    var buckets: [String: [BikeStationLive]] = [:]
    for item in items {
        guard let c = item.station.coordinate else { continue }
        let key = "\(Int((c.latitude / cellLat).rounded()))_\(Int((c.longitude / cellLon).rounded()))"
        buckets[key, default: []].append(item)
    }
    return buckets.map { key, group in
        let coords = group.compactMap(\.station.coordinate)
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return BikeCluster(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), stations: group)
    }
}

/// One map annotation — either a real station or a bubble standing in for several.
/// `Map`'s `MapContentBuilder` doesn't reliably type-check a `ForEach` nested inside
/// another `ForEach`'s branch, so callers flatten to this single-level list instead of
/// looping over clusters and then over each cluster's stations.
enum BikeMapItem: Identifiable {
    /// Coordinate carried alongside the station so rendering never needs an `if let`
    /// inside the `Map` builder closure — every case here is unconditionally drawable.
    case station(BikeStationLive, CLLocationCoordinate2D)
    case cluster(BikeCluster)
    var id: String {
        switch self {
        case .station(let s, _): return "s_\(s.id)"
        case .cluster(let c): return "c_\(c.id)"
        }
    }
}

func bikeMapItems(_ items: [BikeStationLive], span: MKCoordinateSpan) -> [BikeMapItem] {
    clusterBikeStations(items, span: span).flatMap { cluster -> [BikeMapItem] in
        if cluster.shouldBubble { return [.cluster(cluster)] }
        return cluster.stations.compactMap { s in
            guard let c = s.station.coordinate else { return nil }
            return .station(s, c)
        }
    }
}

@MainActor
@Observable
final class MetroNearbyViewModel {
    var items: [MetroStationLive] = []
    var isLoading = false
    var errorText: String?

    func load(near location: CLLocation, operator op: MetroOperator) async {
        isLoading = items.isEmpty
        errorText = nil
        defer { isLoading = false }
        let stations = await MetroService.shared.nearbyStations(operator: op, near: location.coordinate)
        let here = location
        var board: [MetroLiveBoard] = []
        if op.hasLiveBoard {
            board = (try? await MetroService.shared.liveBoard(operator: op)) ?? []
        }
        let byStation = Dictionary(grouping: board, by: \.stationID)
        items = stations.map { s in
            var live = MetroStationLive(station: s)
            if let c = s.coordinate {
                live.distance = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
            }
            live.next = (byStation[s.stationID] ?? [])
                .sorted { ($0.estimateTime ?? 99) < ($1.estimateTime ?? 99) }
            return live
        }
    }
}

// MARK: - Nearby view

struct NearbyStopsView: View {
    @State private var location = LocationManager()
    @State private var resolver = RegionResolver.shared
    @State private var mode: NearbyMode = .bus
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    @State private var busVM = NearbyViewModel()
    @State private var bikeVM = BikeNearbyViewModel()
    @State private var metroVM = MetroNearbyViewModel()
    @State private var landmarkVM = LandmarkNearbyViewModel()
    @State private var placeDetailTarget: NearbyLandmark?
    @State private var showAddLandmark = false
    @State private var landmarkQuery = ""
    @State private var landmarkSearchTask: Task<Void, Never>?

    private var region: LocalRegion? { resolver.region }
    private var modes: [NearbyMode] { region?.availableModes ?? [.bus] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if modes.count > 1 {
                    Picker("類型", selection: $mode) {
                        ForEach(modes) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
                content
            }
            .navigationTitle(region?.areaName ?? "附近")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .landmark {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAddLandmark = true } label: { Image(systemName: "plus.circle") }
                    }
                }
            }
            .sheet(isPresented: $showAddLandmark) {
                if let loc = location.location {
                    AddLandmarkView(coordinate: loc.coordinate) {
                        showAddLandmark = false
                    }
                }
            }
            .onAppear { location.request() }
            .onChange(of: modes.map(\.rawValue)) { _, available in
                if !available.contains(mode.rawValue), let first = modes.first { mode = first }
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
            .sheet(item: $placeDetailTarget) { landmark in
                PlaceDetailView(name: landmark.name, coordinate: landmark.coordinate, subtitle: landmark.subtitle)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if location.authorization == .denied || location.authorization == .restricted {
            ContentUnavailableView("需要定位權限", systemImage: "location.slash",
                                   description: Text("請至「設定 › 隱私權 › 定位服務」開啟本 App 的定位權限"))
        } else if let loc = location.location {
            VStack(spacing: 0) {
                map(loc)
                    .frame(height: 240)
                list(loc)
            }
            .task(id: loc.coordinate.latitude) { await resolver.resolve(for: loc) }
            .task(id: taskKey(loc)) { await reload(loc) }
        } else {
            ContentUnavailableView {
                Label("尚未取得位置", systemImage: "location")
            } actions: {
                Button("允許定位") { location.request() }
            }
        }
    }

    // MARK: map

    private func map(_ loc: CLLocation) -> some View {
        Map(position: $camera) {
            UserAnnotation()
            switch mode {
            case .bus:
                ForEach(busVM.stops.prefix(30)) { stop in
                    if let c = stop.coordinate {
                        Marker(stop.displayName, systemImage: "bus", coordinate: c).tint(.blue)
                    }
                }
            case .bike:
                ForEach(bikeMapItems(bikeVM.items, span: visibleSpan)) { entry in
                    if case .station(let item, let c) = entry {
                        Marker("\(item.station.name)（\(item.rent)）", systemImage: "bicycle", coordinate: c)
                            .tint(item.rent == 0 ? .red : (item.rent < 3 ? .orange : .green))
                    } else if case .cluster(let cluster) = entry {
                        Annotation("", coordinate: cluster.coordinate) {
                            Button {
                                withAnimation {
                                    camera = .region(MKCoordinateRegion(
                                        center: cluster.coordinate,
                                        span: MKCoordinateSpan(latitudeDelta: visibleSpan.latitudeDelta / 4,
                                                                longitudeDelta: visibleSpan.longitudeDelta / 4)
                                    ))
                                }
                            } label: {
                                Text(cluster.badgeText)
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 34, minHeight: 34)
                                    .background(cluster.badgeColor, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                }
            case .metro:
                ForEach(metroVM.items.prefix(30)) { item in
                    if let c = item.station.coordinate {
                        Marker(item.station.name, systemImage: "tram.fill", coordinate: c).tint(.indigo)
                    }
                }
            case .landmark:
                ForEach(landmarkVM.items.prefix(30)) { landmark in
                    Marker(landmark.name, systemImage: landmark.category.icon, coordinate: landmark.coordinate)
                        .tint(landmark.category.color)
                }
            }
        }
        .mapControls { MapUserLocationButton(); MapCompass() }
        // .onEnd (not .continuous) — re-bucketing on every touch-move frame mid-gesture is
        // what caused pins to pop in and out while dragging, and it's needless battery
        // drain besides. Settling for a moment before re-clustering also means the
        // animation below has something stable to animate *to*, not a moving target.
        .onMapCameraChange(frequency: .onEnd) { context in
            withAnimation(.easeInOut(duration: 0.3)) {
                visibleSpan = context.region.span
            }
            // Landmarks were only ever loaded around the device's own location — panning
            // the map elsewhere showed nothing new there. Re-center the search on
            // wherever the user actually panned to, same as scrolling a real map app.
            if mode == .landmark {
                let center = CLLocation(latitude: context.region.center.latitude, longitude: context.region.center.longitude)
                Task { await landmarkVM.load(near: center) }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    // MARK: list

    @ViewBuilder
    private func list(_ loc: CLLocation) -> some View {
        List {
            if let err = errorText {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            if mode == .landmark {
                TextField("搜尋地標，例如店名", text: $landmarkQuery)
                    .onChange(of: landmarkQuery) { _, keyword in
                        landmarkSearchTask?.cancel()
                        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                        landmarkSearchTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            if trimmed.isEmpty {
                                await landmarkVM.load(near: loc)
                            } else {
                                await landmarkVM.search(trimmed, near: loc)
                            }
                        }
                    }
            }
            switch mode {
            case .bus:
                ForEach(busVM.stops) { stop in
                    NavigationLink(value: stop) {
                        row(stop.displayName, meters: busVM.distance(stop, loc), trailing: nil)
                    }
                }
            case .bike:
                ForEach(bikeVM.items) { item in
                    NavigationLink(value: item.station) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.station.name)
                                Text("\(Int(item.distance)) m")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            HStack(spacing: 10) {
                                bikeCount("借", item.rent, .green)
                                bikeCount("還", item.ret, .blue)
                            }
                        }
                    }
                }
            case .metro:
                ForEach(metroVM.items) { item in
                    NavigationLink(value: item.station) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.station.name)
                                Spacer()
                                Text("\(Int(item.distance)) m")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if let n = item.next.first {
                                Text("\(n.headingText)　\(n.etaText)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if region?.metroOperator?.hasLiveBoard == false {
                                Text("此系統無即時到站資訊").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            case .landmark:
                ForEach(landmarkVM.items) { landmark in
                    Button {
                        placeDetailTarget = landmark
                    } label: {
                        row(landmark.name, meters: landmark.distance, trailing: nil)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await reload(loc) }
    }

    private func row(_ title: String, meters: CLLocationDistance, trailing: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(Int(meters)) m").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func bikeCount(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.callout.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var errorText: String? {
        switch mode {
        case .bus: return busVM.errorText
        case .bike: return bikeVM.errorText
        case .metro: return metroVM.errorText
        case .landmark: return landmarkVM.errorText
        }
    }

    // MARK: loading

    private func taskKey(_ loc: CLLocation) -> String {
        "\(mode.rawValue)-\(region?.areaName ?? "")-\(Int(loc.coordinate.latitude * 1000))-\(Int(loc.coordinate.longitude * 1000))"
    }

    private func reload(_ loc: CLLocation) async {
        switch mode {
        case .bus:
            if let c = region?.busCity { await busVM.load(near: loc, city: c) }
        case .bike:
            if let c = region?.bikeCity { await bikeVM.load(near: loc, city: c) }
        case .metro:
            if let op = region?.metroOperator { await metroVM.load(near: loc, operator: op) }
        case .landmark:
            await landmarkVM.load(near: loc)
        }
    }
}

// MARK: - Bus stop detail (routes + live ETAs)

@MainActor
@Observable
final class NearbyStopDetailViewModel {
    var arrivals: [StopArrival] = []
    var isLoading = false
    var errorText: String?
    var lastUpdated: Date?

    func refresh(city: BusCity, stopUIDs: [String]) async {
        isLoading = arrivals.isEmpty
        defer { isLoading = false }
        do {
            let combined = try await BusService.shared.arrivals(city: city, stopUIDs: stopUIDs)
            // Merged stops can report the same route+direction from both underlying
            // TDX entries — keep only the better (earlier / more actionable) one.
            var best: [String: StopArrival] = [:]
            for a in combined {
                let key = "\(a.routeName)-\(a.direction)"
                if let existing = best[key], existing.sortKey <= a.sortKey { continue }
                best[key] = a
            }
            arrivals = best.values.sorted {
                $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : natCompare($0.routeName, $1.routeName)
            }
            lastUpdated = Date()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct NearbyStopDetailView: View {
    let city: BusCity
    let stopUIDs: [String]
    let displayName: String
    @State private var model = NearbyStopDetailViewModel()

    var body: some View {
        List {
            if let errorText = model.errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            Section {
                ForEach(model.arrivals) { arrival in
                    NavigationLink {
                        BusRouteDetailView(
                            scope: .city(city),
                            route: BusRoute(
                                routeUID: arrival.routeName,
                                routeName: LocalizedName(zhTw: arrival.routeName, en: nil),
                                departureStopNameZh: nil,
                                destinationStopNameZh: nil
                            )
                        )
                    } label: {
                        HStack {
                            Text(arrival.routeName).font(.headline)
                            Text(arrival.direction == 0 ? "去程" : "返程")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(arrival.displayText)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(color(for: arrival))
                                .monospacedDigit()
                        }
                    }
                }
                if model.arrivals.isEmpty, !model.isLoading {
                    Text("目前沒有路線動態").foregroundStyle(.secondary)
                }
            } header: {
                if let updated = model.lastUpdated {
                    Text("更新於 \(updated.formatted(date: .omitted, time: .standard))")
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.isLoading { ProgressView() } }
        .task {
            while !Task.isCancelled {
                await model.refresh(city: city, stopUIDs: stopUIDs)
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .refreshable { await model.refresh(city: city, stopUIDs: stopUIDs) }
    }

    private func color(for a: StopArrival) -> Color {
        guard let t = a.estimateTime, (a.stopStatus ?? 0) == 0 else { return .secondary }
        if t < 120 { return .red }
        if t < 300 { return .orange }
        return .primary
    }
}
