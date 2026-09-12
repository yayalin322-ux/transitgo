import SwiftUI
import SwiftData
import MapKit

@MainActor
@Observable
final class BusRouteDetailViewModel {
    let scope: BusScope
    let route: BusRoute

    var directions: [RouteDirection] = []
    var selectedDirection: Int = 0
    var estimates: [String: BusEstimate] = [:]
    var liveBuses: [Int: [LiveBus]] = [:]
    var busPositions: [Int: [LiveBusPosition]] = [:]
    var shape: [Int: [CLLocationCoordinate2D]] = [:]
    var routeInfo: BusRouteInfo?
    var schedule: [BusScheduleEntry] = []
    var isLoading = false
    var errorText: String?
    var rateLimited = false
    var lastUpdated: Date?
    /// Computed once when `schedule` loads, not per stop row.
    var nextDepartureCache: String?
    /// Community rating average, Google-Maps style — nil until (if) the backend has one.
    var ratingStats: RouteRatingStats?

    func loadRatingStats() async {
        ratingStats = await RatingService.stats(kind: "bus", route: route.name, system: scope.displayName)
    }

    init(scope: BusScope, route: BusRoute) {
        self.scope = scope
        self.route = route
    }

    var currentStops: [BusRouteStop] {
        directions.first { $0.direction == selectedDirection }?.stops ?? []
    }

    var busesBySequence: [Int: [LiveBus]] {
        Dictionary(grouping: liveBuses[selectedDirection] ?? [], by: \.stopSequence)
    }

    var currentShape: [CLLocationCoordinate2D] { shape[selectedDirection] ?? [] }
    var currentPositions: [LiveBusPosition] { busPositions[selectedDirection] ?? [] }

    func loadStructure() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        // All four are independent — fetch concurrently.
        async let dirsTask = BusService.shared.directions(scope: scope, routeName: route.name)
        async let infoTask = try? await BusService.shared.routeInfo(scope: scope, routeName: route.name)
        async let scheduleTask = (try? await BusService.shared.schedule(scope: scope, routeName: route.name)) ?? []
        async let shapeTask = (try? await BusService.shared.shape(scope: scope, routeName: route.name)) ?? [:]

        do {
            directions = try await dirsTask
            if let first = directions.first { selectedDirection = first.direction }
            errorText = nil
            rateLimited = false
        } catch {
            errorText = error.localizedDescription
            rateLimited = (error as? TDXError)?.isRateLimited ?? false
        }
        routeInfo = await infoTask
        schedule = await scheduleTask
        shape = await shapeTask
        nextDepartureCache = computeNextDeparture()
    }

    func refreshRealtime() async {
        do {
            async let est = BusService.shared.estimates(scope: scope, routeName: route.name)
            async let buses = BusService.shared.liveBuses(scope: scope, routeName: route.name)
            async let pos = BusService.shared.liveBusPositions(scope: scope, routeName: route.name)
            estimates = try await est
            liveBuses = try await buses
            busPositions = (try? await pos) ?? busPositions
            lastUpdated = Date()
            errorText = nil
            rateLimited = false
        } catch {
            errorText = error.localizedDescription
            rateLimited = (error as? TDXError)?.isRateLimited ?? false
        }
    }

    func estimate(for stop: BusRouteStop) -> BusEstimate? {
        estimates["\(selectedDirection)-\(stop.stopUID)"]
    }

    var nextDepartureText: String? { nextDepartureCache }

    func refreshNextDeparture() { nextDepartureCache = computeNextDeparture() }

    /// Best guess of the next departure from the origin for the current direction,
    /// from the schedule (班距表 / 固定時刻). "HH:mm" or nil.
    private func computeNextDeparture() -> String? {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: Date())   // 1 = Sun
        let hm = cal.dateComponents([.hour, .minute], from: Date())
        let nowMin = (hm.hour ?? 0) * 60 + (hm.minute ?? 0)
        func mins(_ s: String) -> Int? {
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : nil
        }
        func runsToday(_ d: ServiceDay?) -> Bool {
            guard let d else { return true }
            let flags = [d.sunday, d.monday, d.tuesday, d.wednesday, d.thursday, d.friday, d.saturday]
            return (flags[wd - 1] ?? 0) == 1
        }
        var best: Int?
        for e in schedule where e.direction == selectedDirection {
            for f in e.frequencys ?? [] where runsToday(f.serviceDay) {
                guard let st = mins(f.startTime), let en = mins(f.endTime) else { continue }
                let cand: Int
                if nowMin < st { cand = st }
                else if nowMin <= en { cand = nowMin + (f.minHeadwayMins ?? 15) }
                else { continue }
                best = min(best ?? cand, cand)
            }
            for t in e.timetables ?? [] where runsToday(t.serviceDay) {
                guard let m = mins(t.time), m >= nowMin else { continue }
                best = min(best ?? m, m)
            }
        }
        guard let b = best, b < 24 * 60 + 120 else { return nil }
        return String(format: "%02d:%02d", (b / 60) % 24, b % 60)
    }

    /// A sensible default alight stop for tracking a specific bus: a few stops ahead of it.
    func defaultTargetStop(after plate: String) -> BusRouteStop? {
        let stops = currentStops
        guard let bus = (liveBuses[selectedDirection] ?? []).first(where: { $0.plate == plate }),
              let idx = stops.firstIndex(where: { $0.stopSequence >= bus.stopSequence }) else {
            return stops.last
        }
        return stops[min(idx + 3, stops.count - 1)]
    }

    /// Stops the bus can still reach — from its current position onward. Used to build
    /// the 上/下車站 pickers so passed stops aren't offered. Falls back to all stops.
    func reachableStops(forPlate plate: String?) -> [BusRouteStop] {
        let stops = currentStops
        guard let plate,
              let bus = (liveBuses[selectedDirection] ?? []).first(where: { $0.plate == plate })
        else { return stops }
        let ahead = stops.filter { $0.stopSequence >= bus.stopSequence }
        return ahead.isEmpty ? stops : ahead
    }

    /// The stop a given bus is currently at / just left.
    func busCurrentStop(plate: String) -> BusRouteStop? {
        guard let bus = (liveBuses[selectedDirection] ?? []).first(where: { $0.plate == plate }) else { return nil }
        return currentStops.first { $0.stopSequence >= bus.stopSequence } ?? currentStops.last
    }

    /// A default alight stop `n` stops after `board`.
    func stopAhead(of board: BusRouteStop, by n: Int) -> BusRouteStop {
        let stops = currentStops
        guard let i = stops.firstIndex(where: { $0.stopUID == board.stopUID }) else {
            return stops.last ?? board
        }
        return stops[min(i + n, stops.count - 1)]
    }
}

struct TrackTarget: Identifiable {
    /// The stop the user is at / boards at.
    let boardStop: BusRouteStop
    var plate: String?
    var id: String { boardStop.stopUID + (plate ?? "") }
}

struct BusRouteDetailView: View {
    @State private var model: BusRouteDetailViewModel
    @State private var tracker = TripTracker.shared
    @State private var trackingTarget: TrackTarget?
    @State private var showInfo = false
    @State private var showMap = true
    @Environment(\.modelContext) private var context
    @Query private var favorites: [FavoriteItem]

    init(scope: BusScope, route: BusRoute) {
        _model = State(initialValue: BusRouteDetailViewModel(scope: scope, route: route))
    }

    private var favorite: FavoriteItem? {
        favorites.first {
            $0.kind == FavoriteKind.busRoute.rawValue &&
            $0.city == model.scope.storageKey &&
            $0.routeName == model.route.name
        }
    }

    var body: some View {
        List {
            if let stats = model.ratingStats, let avg = stats.avg {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    Text(String(format: "%.1f", avg)).font(.subheadline.weight(.semibold))
                    Text("· \(stats.count) 則評分").font(.caption).foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            }

            if model.directions.count > 1 {
                Picker("方向", selection: $model.selectedDirection) {
                    ForEach(model.directions) { Text($0.headingText).tag($0.direction) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .onChange(of: model.selectedDirection) { _, _ in model.refreshNextDeparture() }
            }

            if showMap, !model.currentShape.isEmpty || !model.currentPositions.isEmpty {
                BusRouteMap(
                    shape: model.currentShape,
                    stops: model.currentStops,
                    buses: model.currentPositions,
                    onTapBus: { plate in
                        let board = model.busCurrentStop(plate: plate)
                            ?? model.reachableStops(forPlate: plate).first
                            ?? model.currentStops.first
                        if let board {
                            trackingTarget = TrackTarget(boardStop: board, plate: plate)
                        }
                    }
                )
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            if model.currentStops.isEmpty {
                if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                } else if let errorText = model.errorText {
                    ContentUnavailableView(
                        model.rateLimited ? "查詢有點頻繁" : "暫時載入不到",
                        systemImage: model.rateLimited ? "hourglass" : "exclamationmark.triangle",
                        description: Text(errorText)
                    )
                    .listRowSeparator(.hidden)
                }
            } else if let errorText = model.errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .listRowSeparator(.hidden)
            }

            if model.scope.hasCrowding, AppSettings.shared.crowdingDemoMode {
                Label("擁擠度目前顯示為示範資料，可於「設定」關閉。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            if tracker.isTracking {
                HStack {
                    Label("追蹤中", systemImage: "dot.radiowaves.left.and.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("停止") { Task { await tracker.stop() } }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                }
                .listRowBackground(Color.blue.opacity(0.12))
            }

            Section {
                ForEach(model.currentStops) { stop in
                    stopRow(stop)
                        .contentShape(Rectangle())
                        .onTapGesture { trackingTarget = TrackTarget(boardStop: stop, plate: nil) }
                        .swipeActions(edge: .leading) {
                            Button {
                                trackingTarget = TrackTarget(boardStop: stop, plate: nil)
                            } label: {
                                Label("追蹤", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.scope.displayName)
                        Spacer()
                        if let updated = model.lastUpdated {
                            Text("更新於 \(updated.formatted(date: .omitted, time: .standard))")
                        }
                    }
                    if let ops = model.routeInfo?.operatorNames, !ops.isEmpty {
                        Text(ops).textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMap.toggle() } label: {
                    Image(systemName: showMap ? "map.fill" : "map")
                }
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                }
                Button { toggleFavorite() } label: {
                    Image(systemName: favorite == nil ? "star" : "star.fill")
                }
            }
        }
        .task {
            // Structure and first realtime pull overlap — realtime doesn't depend on it.
            async let structure: Void = model.loadStructure()
            async let rating: Void = model.loadRatingStats()
            await model.refreshRealtime()
            await structure
            await rating
            while !Task.isCancelled {
                // Retry sooner while rate-limited (data is stale), otherwise ease off.
                let wait = model.rateLimited ? 6 : (model.currentStops.isEmpty ? 8 : 25)
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { break }
                if model.currentStops.isEmpty { await model.loadStructure() }
                await model.refreshRealtime()
            }
        }
        .refreshable { await model.refreshRealtime() }
        .sheet(item: $trackingTarget) { target in
            TrackTripSheet(
                scope: model.scope,
                routeName: model.route.name,
                direction: model.selectedDirection,
                stops: model.reachableStops(forPlate: target.plate),
                initialBoardStop: target.boardStop,
                initialAlightStop: model.stopAhead(of: target.boardStop, by: 5),
                plate: target.plate,
                destinationName: model.currentStops.last?.stopName.display
                    ?? model.route.destinationStopNameZh ?? "終點"
            )
        }
        .sheet(isPresented: $showInfo) {
            RouteInfoView(
                routeName: model.route.name,
                scopeName: model.scope.displayName,
                info: model.routeInfo,
                schedule: model.schedule
            )
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: BusRouteStop) -> some View {
        let est = model.estimate(for: stop)
        let buses = model.busesBySequence[stop.stopSequence] ?? []

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.stopName.display)

                ForEach(buses) { bus in
                    Button {
                        trackingTarget = TrackTarget(boardStop: stop, plate: bus.plate)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: bus.atStop ? "bus.fill" : "bus")
                                .font(.caption2).foregroundStyle(.blue)
                            Text(bus.plate)
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if bus.isLowFloor {
                                Image(systemName: "figure.roll").font(.caption2).foregroundStyle(.blue)
                            }
                            if let crowding = bus.crowding {
                                CrowdBadge(crowding: crowding)
                            }
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 9)).foregroundStyle(.blue.opacity(0.5))
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(est?.displayText ?? "—")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(etaColor(est))
                    .monospacedDigit()
                if !(est?.isActionable ?? false), let nd = model.nextDepartureText {
                    Text("預計 \(nd) 發車")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func etaColor(_ est: BusEstimate?) -> Color {
        guard let est, est.isActionable, let t = est.estimateTime else { return .secondary }
        if t < 120 { return .red }
        if t < 300 { return .orange }
        return .primary
    }

    private func toggleFavorite() {
        if let favorite {
            context.delete(favorite)
        } else {
            context.insert(FavoriteItem(
                kind: FavoriteKind.busRoute.rawValue,
                city: model.scope.storageKey,
                routeName: model.route.name,
                title: model.route.name,
                subtitle: "\(model.scope.displayName)．\(model.route.endpointsText)"
            ))
        }
    }
}

// MARK: - Route map

struct BusRouteMap: View {
    let shape: [CLLocationCoordinate2D]
    let stops: [BusRouteStop]
    let buses: [LiveBusPosition]
    var onTapBus: (String) -> Void

    var body: some View {
        Map {
            if shape.count > 1 {
                MapPolyline(coordinates: shape)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(stops) { stop in
                if let c = stop.coordinate {
                    Annotation("", coordinate: c, anchor: .center) {
                        Circle()
                            .fill(.background)
                            .overlay(Circle().stroke(.blue, lineWidth: 1.5))
                            .frame(width: 6, height: 6)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(buses) { bus in
                Annotation(bus.plate, coordinate: bus.coordinate) {
                    Button { onTapBus(bus.plate) } label: {
                        Image(systemName: "bus.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(busColor(bus), in: Circle())
                            .rotationEffect(.degrees(bus.azimuth))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapControls { MapUserLocationButton() }
    }

    private func busColor(_ b: LiveBusPosition) -> Color {
        switch b.crowding?.level {
        case .comfortable: return .green
        case .moderate: return .orange
        case .crowded: return .red
        default: return .blue
        }
    }
}
