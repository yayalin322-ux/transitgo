import SwiftUI

@MainActor
@Observable
final class MetroStationDetailViewModel {
    var board: [MetroLiveBoard] = []
    var isLoading = false
    var errorText: String?
    var lastUpdated: Date?

    var alerts: [MetroAlertItem] = []
    var firstLast: [MetroFirstLastTrip] = []
    /// Destination names (from data.taipei's own 30s "entering platform" feed) reported
    /// as currently entering — TRTC only, tighter latency than TDX's own estimate.
    var enteringNow: Set<String> = []

    func refresh(operator op: MetroOperator, stationID: String, stationName: String) async {
        guard op.hasLiveBoard else { board = []; return }
        isLoading = board.isEmpty
        defer { isLoading = false }
        do {
            async let boardTask = MetroService.shared.liveBoard(operator: op, stationID: stationID)
            async let enteringTask: Set<String> = op == .trtc
                ? TaipeiMetroLiveFeed.enteringNow(stationName: stationName) : []
            board = try await boardTask
            enteringNow = await enteringTask
            lastUpdated = Date()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Whether `row` matches a currently-entering event from the Taipei feed.
    func isEnteringNow(_ row: MetroLiveBoard) -> Bool {
        enteringNow.contains(destinationKey(row))
    }

    private func destinationKey(_ row: MetroLiveBoard) -> String {
        var name = row.destinationStationName?.display ?? (row.tripHeadSign ?? "")
        if name.hasPrefix("往") { name.removeFirst() }
        if name.hasSuffix("站") { name.removeLast() }
        return name
    }

    /// Alerts + first/last timetable rarely change — load once per visit, not every poll.
    func loadStatic(operator op: MetroOperator, stationID: String) async {
        async let alertsTask = try? MetroService.shared.alerts(operator: op)
        async let firstLastTask = try? MetroService.shared.firstLastTimetable(operator: op, stationID: stationID)
        alerts = await alertsTask ?? []
        firstLast = await firstLastTask ?? []
    }

    /// grouped by heading (往X)
    var byHeading: [(heading: String, rows: [MetroLiveBoard])] {
        let groups = Dictionary(grouping: board, by: \.headingText)
        return groups
            .map { (heading: $0.key, rows: $0.value.sorted { ($0.estimateTime ?? 99) < ($1.estimateTime ?? 99) }) }
            .sorted { $0.heading < $1.heading }
    }
}

/// Fare + estimated ride time between the current station and a picked destination.
@MainActor
@Observable
final class MetroFareLookupViewModel {
    var destination: MetroStation?
    var fareGroups: [RailFareGroup] = []
    var travelMinutes: Int?
    var isLoading = false
    var notFound = false

    func lookup(operator op: MetroOperator, from: MetroStation, to: MetroStation) async {
        destination = to
        isLoading = true
        notFound = false
        fareGroups = []
        travelMinutes = nil
        defer { isLoading = false }

        guard let fare = try? await MetroService.shared.odFare(operator: op, from: from.stationID, to: to.stationID) else {
            notFound = true
            return
        }
        fareGroups = Self.groupFares(fare.fares)

        // Only same-line duration is computed — good enough for the common case, and
        // honest (no total shown at all) when a transfer would actually be needed.
        let lines = try? await MetroService.shared.lines(operator: op)
        for line in lines ?? [] {
            guard let segments = try? await MetroService.shared.travelSegments(operator: op, lineID: line.lineID),
                  !segments.isEmpty else { continue }
            let order = Self.stationOrder(segments)
            guard let i = order.firstIndex(of: from.stationID), let j = order.firstIndex(of: to.stationID) else { continue }
            let lo = min(i, j), hi = max(i, j)
            let seconds = segments
                .filter { seg in
                    guard let a = order.firstIndex(of: seg.fromStationID) else { return false }
                    return a >= lo && a < hi
                }
                .reduce(0) { $0 + $1.runTime + $1.stopTime }
            if seconds > 0 { travelMinutes = Int((Double(seconds) / 60).rounded(.up)); break }
        }
    }

    private static func stationOrder(_ segments: [MetroS2SSegment]) -> [String] {
        let sorted = segments.sorted { $0.sequence < $1.sequence }
        var order = sorted.map(\.fromStationID)
        if let last = sorted.last?.toStationID { order.append(last) }
        return order
    }

    private static func groupFares(_ fares: [MetroFareEntry]) -> [RailFareGroup] {
        var full: [RailFare] = []
        var discounted: [String: RailFare] = [:]   // dedup by label
        for f in fares {
            if f.fareClass == 1 {
                full.append(RailFare(label: "全票", price: f.price))
            } else {
                let label = f.citizenCode.map { "優待票（\($0)）" } ?? "優待票"
                if discounted[label] == nil || discounted[label]!.price > f.price {
                    discounted[label] = RailFare(label: label, price: f.price)
                }
            }
        }
        var groups: [RailFareGroup] = []
        if let fullPrice = full.min(by: { $0.price < $1.price }) {
            groups.append(RailFareGroup(title: "全票", rows: [fullPrice]))
        }
        if !discounted.isEmpty {
            groups.append(RailFareGroup(title: "優待票", rows: discounted.values.sorted { $0.price < $1.price }))
        }
        return groups
    }
}

struct MetroStationDetailView: View {
    let `operator`: MetroOperator
    let stationID: String
    let stationName: String

    @State private var model = MetroStationDetailViewModel()
    @State private var fare = MetroFareLookupViewModel()
    @State private var tracker = MetroTripTracker.shared
    @State private var showFarePicker = false

    private var selfStation: MetroStation {
        MetroStation(stationUID: "", stationID: stationID,
                     stationName: LocalizedName(zhTw: stationName, en: nil), stationPosition: nil)
    }

    var body: some View {
        List {
            if let err = model.errorText {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            if !model.alerts.isEmpty {
                Section {
                    ForEach(model.alerts) { a in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(.subheadline.weight(.semibold))
                                if let d = a.description, !d.isEmpty, d != a.title {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            if !`operator`.hasLiveBoard {
                ContentUnavailableView("無即時到站資訊",
                                       systemImage: "tram",
                                       description: Text("TDX 尚未提供 \(`operator`.displayName) 的即時到站看板。"))
            } else if model.board.isEmpty, !model.isLoading {
                Text("目前查無列車動態（可能非營運時間）。").foregroundStyle(.secondary)
            } else {
                ForEach(model.byHeading, id: \.heading) { group in
                    Section {
                        ForEach(group.rows) { row in
                            HStack {
                                Text(row.lineName.display)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.tint.opacity(0.18), in: Capsule())
                                if model.isEnteringNow(row) {
                                    Label("正在進站", systemImage: "tram.fill")
                                        .font(.callout.weight(.bold)).foregroundStyle(.red)
                                } else {
                                    Text(row.etaText)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle((row.estimateTime ?? 9) <= 1 ? .red : .primary)
                                }
                                Spacer()
                                Button {
                                    Task {
                                        await startTracking(heading: group.heading)
                                    }
                                } label: {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!tracker.isActivitiesEnabled)
                            }
                        }
                    } header: {
                        Text(group.heading)
                    }
                }
            }

            if tracker.isTracking, tracker.trackedKey?.hasPrefix("\(`operator`.rawValue)-\(stationID)-") == true {
                Section {
                    Button(role: .destructive) { Task { await tracker.stop() } } label: {
                        Label("停止追蹤", systemImage: "stop.circle")
                    }
                }
            }

            if !model.firstLast.isEmpty {
                Section("首末班車") {
                    ForEach(model.firstLast) { trip in
                        HStack {
                            Text(trip.headingText).font(.subheadline)
                            Spacer()
                            Text("首 \(trip.firstTrainTime)").font(.caption).foregroundStyle(.secondary)
                            Text("末 \(trip.lastTrainTime)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("票價查詢") {
                Button {
                    showFarePicker = true
                } label: {
                    Label(fare.destination == nil ? "選擇目的地站" : "目的地：\(fare.destination!.name)",
                          systemImage: "creditcard")
                }
                if fare.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if fare.notFound {
                    Text("查無票價資料").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(fare.fareGroups) { group in
                        RailFareGroupRow(group: group)
                    }
                    if let mins = fare.travelMinutes {
                        LabeledContent("預估車程", value: "約 \(mins) 分鐘")
                    } else if fare.destination != nil {
                        Text("此區間需轉乘，車程未估算").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle(stationName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.isLoading { ProgressView() } }
        .task {
            await model.loadStatic(operator: `operator`, stationID: stationID)
            while !Task.isCancelled {
                await model.refresh(operator: `operator`, stationID: stationID, stationName: stationName)
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .refreshable { await model.refresh(operator: `operator`, stationID: stationID, stationName: stationName) }
        .sheet(isPresented: $showFarePicker) {
            MetroStationPickerSheet(operator: `operator`, excluding: stationID) { picked in
                showFarePicker = false
                Task { await fare.lookup(operator: `operator`, from: selfStation, to: picked) }
            }
        }
    }

    private func startTracking(heading: String) async {
        let station = MetroLineStation(sequence: 0, stationID: stationID,
                                       stationName: LocalizedName(zhTw: stationName, en: nil))
        let lineName = model.board.first?.lineName.display ?? ""
        await tracker.start(operator: `operator`, station: station,
                            systemName: `operator`.displayName, lineName: lineName, heading: heading)
    }
}

/// Searchable picker over every station of one operator, for the fare/travel-time lookup.
private struct MetroStationPickerSheet: View {
    let `operator`: MetroOperator
    let excluding: String
    let onPick: (MetroStation) -> Void

    @State private var stations: [MetroStation] = []
    @State private var keyword = ""

    private var filtered: [MetroStation] {
        let base = stations.filter { $0.stationID != excluding }
        guard !keyword.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { s in
                Button { onPick(s) } label: {
                    Text(s.name).foregroundStyle(.primary)
                }
            }
            .navigationTitle("選擇目的地站")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "站名")
            .task { stations = await MetroStationStore.shared.stations(operator: `operator`) }
        }
        .presentationDetents([.medium, .large])
    }
}
