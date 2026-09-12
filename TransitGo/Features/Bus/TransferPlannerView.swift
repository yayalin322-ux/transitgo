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

    var itineraries: [TransferItinerary] = []
    var metroItineraries: [MetroItinerary] = []
    var isPlanning = false
    var errorText: String?

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

    private static func searchLandmarks(_ keyword: String, near: CLLocationCoordinate2D) async -> [DestinationCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        request.region = MKCoordinateRegion(center: near, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(8).compactMap { item in
            guard let name = item.name else { return nil }
            return DestinationCandidate(
                name: name, subtitle: item.placemark.title, coordinate: item.placemark.coordinate, isLandmark: true
            )
        }
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
        defer { isPlanning = false }

        async let busResult = TransferPlanner.plan(city: city, from: origin, to: dest)
        let metroResult: [MetroItinerary]
        if let op = metroOperator {
            metroResult = await MetroTransferPlanner.planNearby(operator: op, from: origin, to: dest)
        } else {
            metroResult = []
        }
        let bus = await busResult
        itineraries = bus.itineraries
        metroItineraries = metroResult

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

struct TransferPlannerView: View {
    let city: BusCity
    let origin: CLLocationCoordinate2D
    var metroOperator: MetroOperator?

    @Environment(\.dismiss) private var dismiss
    @State private var model = TransferPlannerViewModel()
    @State private var path = NavigationPath()
    @State private var showBikePicker = false
    @State private var navTarget: NavTarget?
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
    }

    private var effectiveOrigin: CLLocationCoordinate2D { model.originOverride?.coordinate ?? origin }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("起點") {
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
                    TextField("站名或地標，例如 台北101、台北車站", text: $model.destinationText)
                        .onChange(of: model.destinationText) { _, v in model.searchDestination(v, city: city, near: effectiveOrigin) }
                    if let d = model.destination {
                        Label(d.name, systemImage: d.isLandmark ? "mappin.circle.fill" : "bus.fill")
                            .foregroundStyle(.blue)
                    }
                    ForEach(model.destinationResults) { candidate in
                        Button {
                            model.destination = candidate
                            model.destinationText = candidate.name
                            model.destinationResults = []
                            Task { await model.planAll(city: city, metroOperator: metroOperator, from: effectiveOrigin) }
                        } label: {
                            candidateLabel(candidate)
                        }
                    }
                }

                if model.isPlanning {
                    Section { HStack { Spacer(); ProgressView("規劃路線中…"); Spacer() } }
                }
                if let err = model.errorText, !model.isPlanning {
                    Section { Text(err).font(.footnote).foregroundStyle(.secondary) }
                    travelTimesSection
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
                InAppNavigationView(destination: target.coordinate, destinationName: target.name, transportType: target.transportType)
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
                    navigate(mode: .automobile)
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

    private func navigate(mode: MKDirectionsTransportType) {
        guard let dest = model.travelDestination else { return }
        let name = model.destination?.name ?? "目的地"
        navTarget = NavTarget(coordinate: dest, name: name, transportType: mode)
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
