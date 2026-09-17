import SwiftUI
import CoreLocation
import MapKit

/// A destination the user picked — either a real bus stop (rides end there exactly) or a
/// landmark/address (the planner treats its coordinate as "get me near here").
struct DestinationCandidate: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D
    let isLandmark: Bool
}

@MainActor
@Observable
final class TransferPlannerViewModel {
    // One shared origin/destination search — feeds bus AND metro planning together, so
    // the user picks a place once instead of choosing a mode first and hoping it's right.
    var originText = ""
    var originResults: [DestinationCandidate] = []
    var originOverride: DestinationCandidate?
    var destinationText = ""
    var destinationResults: [DestinationCandidate] = []
    var destination: DestinationCandidate?
    /// Shared by the multimodal (new-engine) planner — defaults to "now", but the user
    /// can move it, e.g. to check tomorrow morning's first bus.
    var multimodalDepartAt = Date()

    var itineraries: [TransferItinerary] = []
    var metroItineraries: [MetroItinerary] = []
    var isPlanning = false
    var errorText: String?

    // The new multimodal routing engine — real data, but only where it's actually been
    // ingested so far (currently 新竹市/新竹縣公車 only). Empty/nil here means "this
    // engine has no real data for this area yet", not "no route exists" — the existing
    // bus/metro/rail sections above stay the primary planners.
    var multimodalRoutes: [MultimodalRoute] = []
    // Debug-visible while this feature is new — shows exactly why multimodalRoutes is
    // empty (unreachable vs. server said no route) instead of leaving it unexplained.
    var multimodalDebug: String?
    // Real, backend-reported coverage (RoutingCoverageService) — replaces a hand-typed
    // sentence that goes stale the moment a new city/feed is ingested. nil until loaded.
    var coverageText: String?

    // Rail — kept as its own always-visible section, since TRA stations have no
    // coordinate in this app, so there's no way to fold it into the same coordinate
    // search the way bus/metro share one.
    var railOriginText = ""
    var railOrigin: RailStation?
    var railDestinationText = ""
    var railDestination: RailStation?
    var railItineraries: [RailItinerary] = []
    var isPlanningRail = false
    var railErrorText: String?

    // Fallback when nothing transit-wise was found — how long the alternatives take.
    var travelTimes: TravelTimeOptions?
    var isLoadingTravelTimes = false
    var travelOrigin: CLLocationCoordinate2D?
    var travelDestination: CLLocationCoordinate2D?

    private var searchTask: Task<Void, Never>?
    private var originSearchTask: Task<Void, Never>?

    /// Searches TDX bus-stop names AND general landmarks/addresses (via on-device MapKit
    /// search, no API key needed) in parallel, so "台北101" works just as well as an exact
    /// stop name — the planner only needs *a coordinate* for the destination either way.
    func searchDestination(_ text: String, city: BusCity, near: CLLocationCoordinate2D) {
        searchTask?.cancel()
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard keyword.count >= 1 else { destinationResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            async let stopsTask = Self.searchStops(keyword, city: city)
            async let landmarksTask = Self.searchLandmarks(keyword, near: near)
            let stops = await stopsTask
            let landmarks = await landmarksTask
            if !Task.isCancelled { destinationResults = stops + landmarks }
        }
    }

    func searchOrigin(_ text: String, city: BusCity, near: CLLocationCoordinate2D) {
        originSearchTask?.cancel()
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard keyword.count >= 1 else { originResults = []; return }
        originSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            async let stopsTask = Self.searchStops(keyword, city: city)
            async let landmarksTask = Self.searchLandmarks(keyword, near: near)
            let stops = await stopsTask
            let landmarks = await landmarksTask
            if !Task.isCancelled { originResults = stops + landmarks }
        }
    }

    private static func searchStops(_ keyword: String, city: BusCity) async -> [DestinationCandidate] {
        let escaped = keyword.replacingOccurrences(of: "'", with: "''")
        let raw: [NearbyStop] = (try? await TDXClient.shared.get(
            "v2/Bus/Stop/City/\(city.rawValue)",
            query: [
                "$filter": "contains(StopName/Zh_tw,'\(escaped)')",
                "$select": "StopUID,StopName,StopPosition",
                "$top": "10",
            ]
        )) ?? []
        return raw.compactMap { s in
            guard let c = s.coordinate else { return nil }
            return DestinationCandidate(name: s.stopName.display, subtitle: "公車站", coordinate: c, isLandmark: false)
        }
    }

    /// A landmark like "台北101" pulls in every shop/restaurant/office inside the same
    /// building that merely mentions it, plus other unrelated same-named places across
    /// the region — MapKit's own relevance ordering doesn't reliably put the actual
    /// building first among those, so a real search (e.g. "101世貿") could return 8
    /// results without the landmark itself in there at all. Re-rank by actual name
    /// match first, then distance, and collapse near-duplicate entries (sub-tenants of
    /// the same building) down to one.
    private static func searchLandmarks(_ keyword: String, near: CLLocationCoordinate2D) async -> [DestinationCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        request.region = MKCoordinateRegion(center: near, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let nearLoc = CLLocation(latitude: near.latitude, longitude: near.longitude)

        func matchRank(_ name: String) -> Int {
            let n = name.lowercased(), k = keyword.lowercased()
            if n == k { return 0 }
            if n.hasPrefix(k) || k.hasPrefix(n) { return 1 }
            if n.contains(k) { return 2 }
            return 3   // matched on something other than its own name (category, address…)
        }

        let ranked = response.mapItems.compactMap { item -> (item: MKMapItem, rank: Int, distance: CLLocationDistance)? in
            guard let name = item.name else { return nil }
            let d = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude).distance(from: nearLoc)
            return (item, matchRank(name), d)
        }.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.distance < $1.distance }

        var out: [DestinationCandidate] = []
        for entry in ranked {
            let c = entry.item.placemark.coordinate
            // Same building's sub-tenants land within a few metres of each other —
            // keep only the first (best-ranked) one per cluster.
            let isDuplicate = out.contains { existing in
                CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 40
            }
            guard !isDuplicate, let name = entry.item.name else { continue }
            out.append(DestinationCandidate(name: name, subtitle: entry.item.placemark.title, coordinate: c, isLandmark: true))
            if out.count >= 8 { break }
        }
        return out
    }

    /// Runs bus AND metro planning together (metro skipped where the region has none) and
    /// only falls back to drive/walk/bike estimates once *both* come back empty — one
    /// search, whichever mode actually has an answer.
    func planAll(city: BusCity, metroOperator: MetroOperator?, from origin: CLLocationCoordinate2D) async {
        guard let dest = destination?.coordinate else { return }
        // Give the backend a head start waking up (Render free tier sleeps when idle) —
        // by the time the user scrolls to and taps the YouBike option, it's had several
        // seconds/tens of seconds to come back, instead of the picker's own request being
        // the one that has to eat the full cold-start delay.
        Prewarm.wakeBackend()
        isPlanning = true
        errorText = nil
        travelTimes = nil
        itineraries = []
        metroItineraries = []
        multimodalRoutes = []
        multimodalDebug = nil
        defer { isPlanning = false }

        async let busResult = TransferPlanner.plan(city: city, from: origin, to: dest)
        async let multimodalResult = MultimodalRoutingService.plan(from: origin, to: dest, departureTime: multimodalDepartAt)
        let metroResult: [MetroItinerary]
        if let op = metroOperator {
            metroResult = await MetroTransferPlanner.planNearby(operator: op, from: origin, to: dest)
        } else {
            metroResult = []
        }
        let bus = await busResult
        itineraries = bus.itineraries
        metroItineraries = metroResult
        switch await multimodalResult {
        case .success(let routes):
            multimodalRoutes = routes
            multimodalDebug = routes.isEmpty ? "多模式引擎：此範圍暫無真實路線" : nil
        case .serverError(let code, let message):
            multimodalDebug = "多模式引擎：\(code) \(message)\n起點(\(origin.latitude),\(origin.longitude)) 終點(\(dest.latitude),\(dest.longitude))"
        case .unreachable(let reason):
            multimodalDebug = "多模式引擎連線失敗：\(reason)"
        }

        if itineraries.isEmpty, metroItineraries.isEmpty {
            // Distinguish "TDX genuinely has nothing" from "TDX didn't actually answer" —
            // this session hammered TDX hard enough during debugging that the second case
            // is common right now, and telling the user "no route exists" would be wrong.
            errorText = bus.hadNetworkError
                ? "查詢時 TDX 沒有正常回應（可能是限流），不代表真的沒有路線 — 稍後再試一次看看。"
                : "找不到直達或單次轉乘的公車／捷運路線。"
            await loadTravelTimes(from: origin, to: dest)
        }
    }

    private func loadTravelTimes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async {
        isLoadingTravelTimes = true
        defer { isLoadingTravelTimes = false }
        travelOrigin = origin
        travelDestination = destination
        travelTimes = await TravelTimeEstimator.estimate(from: origin, to: destination)
    }

    func railStations(matching text: String) -> [RailStation] {
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return [] }
        return RailStationStore.shared.stations(for: .tra)
            .filter { $0.name.localizedCaseInsensitiveContains(keyword) }
            .prefix(15)
            .map { $0 }
    }

    func planRail(near: CLLocationCoordinate2D, date: Date) async {
        guard let o = railOrigin, let d = railDestination else { return }
        isPlanningRail = true
        railErrorText = nil
        defer { isPlanningRail = false }
        railItineraries = await RailTransferPlanner.plan(from: o, to: d, date: date)
        if railItineraries.isEmpty {
            railErrorText = "今日查無合適班次（可能需要轉乘超過一次，或已過末班車）。"
            // No coordinates for TRA stations in this app — best-effort geocode by name.
            if let originCoord = await TravelTimeEstimator.geocode(o.name + "車站", near: near),
               let destCoord = await TravelTimeEstimator.geocode(d.name + "車站", near: near) {
                await loadTravelTimes(from: originCoord, to: destCoord)
            }
        }
    }
}

/// Wraps a multi-leg trip so it can drive `.fullScreenCover(item:)` the same way the
/// single-destination `NavTarget` does.
struct MultimodalNavTarget: Identifiable {
    let id = UUID()
    let legs: [NavigationLeg]
    let tripName: String
}

/// Real per-boarding segments (from the routing engine's own ingested data) → the
/// sequential legs InAppNavigationView already knows how to run: a WALK segment becomes
/// a real turn-by-turn walking leg to the next boarding point; a BUS/TRA/METRO segment
/// becomes a "ride" leg (see NavigationLeg.transitLabel) with no route to draw — just
/// live-position tracking that auto-advances once GPS says we're near the alight stop.
/// Segments missing a real coordinate (backend couldn't resolve that stop's lat/lon) are
/// skipped rather than guessed — the trip still runs, just without a leg for that hop.
private func navigationLegs(for route: MultimodalRoute) -> [NavigationLeg] {
    route.segments.compactMap { seg -> NavigationLeg? in
        guard let coord = seg.toCoordinate else { return nil }
        let name = seg.toName ?? (seg.mode == "WALK" ? "轉乘點" : "下車站")
        if seg.mode == "WALK" {
            return NavigationLeg(coordinate: coord, name: name, transportType: .walking)
        }
        return NavigationLeg(
            coordinate: coord, name: name, transportType: .transit, transitLabel: seg.modeLabel,
            transitRouteName: seg.routeShortName, transitScopePath: seg.scopePath
        )
    }
}

struct TransferPlannerView: View {
    let city: BusCity
    let origin: CLLocationCoordinate2D
    var metroOperator: MetroOperator?

    @Environment(\.dismiss) private var dismiss
    @State private var model = TransferPlannerViewModel()
    @State private var path = NavigationPath()
    @State private var showBikePicker = false
    @State private var navTarget: NavTarget?
    @State private var multimodalNavTarget: MultimodalNavTarget?
    /// Only wired into 台鐵 for now — bus/metro discovery here is built on TDX's *live*
    /// arrival feed, not the schedule timetable, so it can't honestly answer "is there
    /// service at 8am" for a time other than now. To check that, open the route/line from
    /// the results and look at its own 時刻表 section.
    @State private var railDepartAt = Date()

    struct NavTarget: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let name: String
        let transportType: MKDirectionsTransportType
        var avoidsHighways: Bool? = nil
    }

    private var effectiveOrigin: CLLocationCoordinate2D { model.originOverride?.coordinate ?? origin }
    @State private var editingSavedPlaceRole: SavedPlaceRole?
    @State private var placeDetailTarget: DestinationCandidate?

    @ViewBuilder
    private func savedPlaceChips(onSelect: @escaping (SavedPlace) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(SavedPlaceRole.allCases) { role in
                Button {
                    if let place = SavedPlaceStore.get(role) {
                        onSelect(place)
                    } else {
                        editingSavedPlaceRole = role
                    }
                } label: {
                    Label(SavedPlaceStore.get(role)?.name ?? "設定\(role.label)", systemImage: role.icon)
                        .font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)
                .contextMenu {
                    if SavedPlaceStore.get(role) != nil {
                        Button("重新設定") { editingSavedPlaceRole = role }
                        Button("清除", role: .destructive) { SavedPlaceStore.clear(role) }
                    }
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("起點") {
                    savedPlaceChips { place in
                        model.originOverride = DestinationCandidate(name: place.name, subtitle: nil, coordinate: place.coordinate, isLandmark: true)
                        model.originText = place.name
                        if model.destination != nil { Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) } }
                    }
                    TextField("預設為目前位置，可改搜尋站名或地標", text: $model.originText)
                        .onChange(of: model.originText) { _, v in model.searchOrigin(v, city: city, near: origin) }
                    Label(model.originOverride?.name ?? "目前位置",
                          systemImage: model.originOverride == nil ? "location.fill" : (model.originOverride!.isLandmark ? "mappin.circle.fill" : "bus.fill"))
                        .foregroundStyle(.blue)
                    ForEach(model.originResults) { candidate in
                        Button {
                            model.originOverride = candidate
                            model.originText = candidate.name
                            model.originResults = []
                            if model.destination != nil { Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) } }
                        } label: {
                            candidateLabel(candidate)
                        }
                    }
                    if model.originOverride != nil {
                        Button("改回目前位置") {
                            model.originOverride = nil
                            model.originText = ""
                            if model.destination != nil { Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) } }
                        }
                    }
                }

                Section("目的地") {
                    savedPlaceChips { place in
                        model.destination = DestinationCandidate(name: place.name, subtitle: nil, coordinate: place.coordinate, isLandmark: true)
                        model.destinationText = place.name
                        Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) }
                    }
                    TextField("站名或地標，例如 台北101、台北車站", text: $model.destinationText)
                        .onChange(of: model.destinationText) { _, v in model.searchDestination(v, city: city, near: effectiveOrigin) }
                    if let d = model.destination {
                        HStack {
                            Label(d.name, systemImage: d.isLandmark ? "mappin.circle.fill" : "bus.fill")
                                .foregroundStyle(.blue)
                            if d.isLandmark {
                                Spacer()
                                Button { placeDetailTarget = d } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(model.destinationResults) { candidate in
                        HStack {
                            Button {
                                model.destination = candidate
                                model.destinationText = candidate.name
                                model.destinationResults = []
                                Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) }
                            } label: {
                                candidateLabel(candidate)
                            }
                            if candidate.isLandmark {
                                Spacer()
                                Button { placeDetailTarget = candidate } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    DatePicker("多模式出發時間", selection: $model.multimodalDepartAt)
                        .onChange(of: model.multimodalDepartAt) { _, _ in
                            if model.destination != nil { Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) } }
                        }
                }

                if model.isPlanning {
                    Section { HStack { Spacer(); ProgressView("規劃路線中…"); Spacer() } }
                }
                if let err = model.errorText, !model.isPlanning {
                    Section { Text(err).font(.footnote).foregroundStyle(.secondary) }
                    travelTimesSection
                }

                if let debug = model.multimodalDebug, !model.isPlanning {
                    Section { Text(debug).font(.caption2).foregroundStyle(.orange) }
                }

                ForEach(model.multimodalRoutes) { route in
                    Section {
                        ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, seg in
                            HStack(alignment: .top, spacing: 10) {
                                stepBadge(index)
                                Image(systemName: seg.modeIcon).foregroundStyle(.blue).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    if seg.mode == "WALK" {
                                        Text("走路 \(seg.durationSeconds / 60) 分鐘")
                                            .font(.subheadline)
                                    } else {
                                        Text(seg.modeLabel).font(.subheadline.weight(.semibold))
                                        if let from = seg.fromName {
                                            Text("上車：\(from)" + (seg.departureClock.map { " (\($0)) " } ?? ""))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let to = seg.toName {
                                            Text("下車：\(to)" + (seg.arrivalClock.map { " (\($0)) " } ?? "") + (seg.stopsPassed > 1 ? "・經過\(seg.stopsPassed)站" : ""))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        Button {
                            let legs = navigationLegs(for: route)
                            guard !legs.isEmpty else { return }
                            multimodalNavTarget = MultimodalNavTarget(legs: legs, tripName: model.destination?.name ?? "目的地")
                        } label: {
                            Label("開始導航", systemImage: "location.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("多模式・\(route.label)")
                            if let summary = route.summaryText {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                            // "共1小時24分・轉乘2次・步行680m・約NT$165" — omits any piece
                            // the backend didn't actually send a real value for (walking
                            // distance on an older deploy) rather than show a fake 0.
                            Text([
                                "共\(route.durationSeconds >= 3600 ? "\(route.durationSeconds / 3600)小時" : "")\(route.durationSeconds % 3600 / 60)分",
                                "轉乘\(route.transfers)次",
                                route.walkingDistanceText,
                                route.fareText,
                            ].compactMap { $0 }.joined(separator: "・"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                    } footer: {
                        if route.id == model.multimodalRoutes.first?.id {
                            // Real, backend-reported coverage — see RoutingCoverageService.
                            // Falls back to a coverage-free sentence rather than a stale
                            // hand-typed one if the coverage call hasn't come back yet.
                            let coverage = model.coverageText.map { "目前支援：\($0)" } ?? "涵蓋範圍載入中"
                            Text("新路線引擎（搭乘段落是被動追蹤，不會畫出公車實際行駛路線；票價尚未有真實資料來源）\n\(coverage)")
                        }
                    }
                }

                ForEach(model.metroItineraries) { itinerary in
                    Section(itinerary.legs.first.map { "捷運・\($0.lineName)" } ?? "捷運") {
                        ForEach(itinerary.legs) { leg in
                            NavigationLink(value: leg) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("上車：\(leg.fromStation.name)").font(.subheadline)
                                    Text("下車：\(leg.toStation.name)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                ForEach(model.itineraries) { itinerary in
                    Section(itinerary.isDirect ? "公車・直達" : "公車・轉乘一次") {
                        ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                            NavigationLink(value: leg) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        stepBadge(index)
                                        Text(leg.routeName).font(.headline)
                                    }
                                    Text("上車：\(leg.boardStop.stopName.display)").font(.subheadline)
                                    Text("下車：\(leg.alightStop.stopName.display)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                railContent
            }
            .navigationTitle("轉乘規劃")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .task { await RailStationStore.shared.loadIfNeeded() }
            .task { model.coverageText = await RoutingCoverageService.current()?.summaryText }
            .navigationDestination(for: TransferLeg.self) { leg in
                BusRouteDetailView(
                    scope: leg.scope,
                    route: BusRoute(routeUID: leg.routeName,
                                    routeName: LocalizedName(zhTw: leg.routeName, en: nil),
                                    departureStopNameZh: nil, destinationStopNameZh: nil)
                )
            }
            .navigationDestination(for: MetroLeg.self) { leg in
                if let op = metroOperator {
                    MetroStationDetailView(operator: op, stationID: leg.fromStation.stationID, stationName: leg.fromStation.name)
                }
            }
            .sheet(isPresented: $showBikePicker) {
                if let dest = model.travelDestination {
                    YouBikeLegPickerView(destination: dest, anchor: model.travelOrigin ?? effectiveOrigin)
                }
            }
            .fullScreenCover(item: $navTarget) { target in
                InAppNavigationView(destination: target.coordinate, destinationName: target.name, transportType: target.transportType, avoidsHighways: target.avoidsHighways)
            }
            .fullScreenCover(item: $multimodalNavTarget) { target in
                InAppNavigationView(legs: target.legs, tripName: target.tripName)
            }
            .sheet(item: $editingSavedPlaceRole) { role in
                SetSavedPlaceView(role: role, near: origin)
            }
            .sheet(item: $placeDetailTarget) { candidate in
                PlaceDetailView(name: candidate.name, coordinate: candidate.coordinate, subtitle: candidate.subtitle)
            }
        }
    }

    // MARK: - Rail (always-visible secondary section — needs manual station names)

    @ViewBuilder
    private var railContent: some View {
        Section("台鐵（需輸入起訖站名）") {
            DatePicker("出發時間", selection: $railDepartAt)
                .onChange(of: railDepartAt) { _, _ in
                    if model.railOrigin != nil, model.railDestination != nil {
                        Task { await model.planRail(near: origin, date: railDepartAt) }
                    }
                }
            TextField("起站", text: $model.railOriginText)
            ForEach(model.railStations(matching: model.railOriginText)) { s in
                Button {
                    model.railOrigin = s
                    model.railOriginText = s.name
                    if model.railDestination != nil { Task { await model.planRail(near: origin, date: railDepartAt) } }
                } label: {
                    Text(s.name).foregroundStyle(.primary)
                }
            }
            TextField("到站", text: $model.railDestinationText)
            ForEach(model.railStations(matching: model.railDestinationText)) { s in
                Button {
                    model.railDestination = s
                    model.railDestinationText = s.name
                    if model.railOrigin != nil { Task { await model.planRail(near: origin, date: railDepartAt) } }
                } label: {
                    Text(s.name).foregroundStyle(.primary)
                }
            }
        }

        if model.isPlanningRail {
            Section { HStack { Spacer(); ProgressView("規劃路線中…"); Spacer() } }
        }
        if let err = model.railErrorText, !model.isPlanningRail {
            Section { Text(err).font(.footnote).foregroundStyle(.secondary) }
        }

        ForEach(model.railItineraries) { itinerary in
            Section {
                ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            stepBadge(index)
                            Text("\(leg.train.trainType) \(leg.train.trainNo)").font(.headline)
                            Spacer()
                            Text(leg.train.durationText).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("\(leg.fromStation.name) \(leg.train.departure) 發車")
                            Spacer()
                            Text("\(leg.toStation.name) \(leg.train.arrival) 到達")
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: {
                let total = Fmt.duration(from: itinerary.legs.first?.train.departure ?? "", to: itinerary.legs.last?.train.arrival ?? "")
                if itinerary.isDirect {
                    Text("直達・全程約\(total)")
                } else if let wait = itinerary.transferWaitMinutes {
                    Text("在 \(itinerary.legs[0].toStation.name) 轉車・等 \(wait) 分鐘・全程約\(total)")
                } else {
                    Text("轉乘一次・全程約\(total)")
                }
            }
        }
    }

    private func stepBadge(_ index: Int) -> some View {
        Text("\(index + 1)").font(.caption2.bold())
            .frame(width: 16, height: 16)
            .background(.tint, in: Circle())
            .foregroundStyle(.white)
    }

    private func candidateLabel(_ candidate: DestinationCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.isLandmark ? "mappin.circle.fill" : "bus.fill")
                .foregroundStyle(candidate.isLandmark ? .red : .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name).foregroundStyle(.primary)
                if let sub = candidate.subtitle, candidate.isLandmark {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Travel time fallback (no transit route found)

    @ViewBuilder
    private var travelTimesSection: some View {
        if model.isLoadingTravelTimes {
            Section { HStack { Spacer(); ProgressView("估算開車／騎車／走路時間中…"); Spacer() } }
        } else if let t = model.travelTimes, !t.isEmpty {
            Section {
                travelTimeRow("開車", minutes: t.driveMinutes, icon: "car.fill", color: .blue) {
                    navigate(mode: .automobile)
                }
                travelTimeRow("騎機車", minutes: t.scooterMinutes, icon: "figure.outdoor.cycle", color: .orange) {
                    // Scooters are legally banned from Taiwan's freeways — same
                    // .automobile transport type as 開車 (MapKit has no scooter mode),
                    // but this leg must avoid 國道 unlike an actual car trip.
                    navigate(mode: .automobile, avoidsHighways: true)
                }
                travelTimeRow("YouBike", minutes: t.bikeMinutes, icon: "bicycle", color: .green) {
                    showBikePicker = true
                }
                travelTimeRow("腳踏車（自備）", minutes: t.ownBikeMinutes, icon: "bicycle.circle.fill", color: .mint) {
                    navigate(mode: .cycling)
                }
                travelTimeRow("走路", minutes: t.walkMinutes, icon: "figure.walk", color: .secondary) {
                    navigate(mode: .walking)
                }
            } header: {
                Text("其他交通方式（估算）")
            } footer: {
                Text("騎機車、YouBike 時間非實際路線計算，僅供參考。「導航」是 App 自己畫路線、跟著你的位置走、偏離會自動重新規劃；YouBike 會先幫你挑一個真的有車（可指定要有電輔車）的站點。")
            }
        }
    }

    private func navigate(mode: MKDirectionsTransportType, avoidsHighways: Bool? = nil) {
        guard let dest = model.travelDestination else { return }
        let name = model.destination?.name ?? "目的地"
        navTarget = NavTarget(coordinate: dest, name: name, transportType: mode, avoidsHighways: avoidsHighways)
    }

    private func travelTimeRow(_ label: String, minutes: Int?, icon: String, color: Color, onNavigate: @escaping () -> Void) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundStyle(color)
            Spacer()
            if let m = minutes {
                Text(m < 60 ? "\(m) 分鐘" : "\(m / 60) 小時 \(m % 60) 分")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Button("導航") { onNavigate() }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}
