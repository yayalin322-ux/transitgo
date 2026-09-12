import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Kind

enum TimetableKind: String, AppEnum {
    case railTRA
    case railTHSR
    case busStop
    case metro
    case bike

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "類型" }
    static var caseDisplayRepresentations: [TimetableKind: DisplayRepresentation] {
        [.railTRA: "台鐵", .railTHSR: "高鐵", .busStop: "公車到站",
         .metro: "捷運到站", .bike: "YouBike"]
    }
}

enum BusDirectionOption: String, AppEnum {
    case outbound
    case inbound
    var value: Int { self == .outbound ? 0 : 1 }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "方向" }
    static var caseDisplayRepresentations: [BusDirectionOption: DisplayRepresentation] {
        [.outbound: "去程", .inbound: "返程"]
    }
}

// MARK: - Pickable entities (menus instead of free text)

/// 台鐵／高鐵車站。id = "TRA:1000"。
struct RailStationEntity: AppEntity {
    let id: String
    let name: String
    var systemRaw: String { String(id.prefix(while: { $0 != ":" })) }
    var stationID: String { String(id.drop(while: { $0 != ":" }).dropFirst()) }
    var system: RailSystem { RailSystem(rawValue: systemRaw) ?? .tra }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "車站" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)｜\(system.displayName)")
    }
    static var defaultQuery = RailStationEntityQuery()
}

struct RailStationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RailStationEntity] {
        let all = await Self.catalog()
        return all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RailStationEntity] {
        let all = await Self.catalog()
        guard !string.isEmpty else { return Array(all.prefix(40)) }
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [RailStationEntity] {
        await Self.catalog()
    }

    static func catalog() async -> [RailStationEntity] {
        await RailStationStore.shared.loadIfNeeded()
        return await MainActor.run {
            let tra = RailStationStore.shared.stations(for: .tra)
                .map { RailStationEntity(id: "TRA:\($0.id)", name: $0.name) }
            let thsr = RailStationStore.shared.stations(for: .thsr)
                .map { RailStationEntity(id: "THSR:\($0.id)", name: $0.name) }
            return tra + thsr
        }
    }
}

/// 公車地區（含公路客運）。id = BusScope.storageKey。
struct BusRegionEntity: AppEntity {
    let id: String
    let name: String
    var scope: BusScope { BusScope(storageKey: id) ?? .city(.taipei) }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "地區" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = BusRegionEntityQuery()
}

struct BusRegionEntityQuery: EntityQuery {
    private var all: [BusRegionEntity] {
        BusScope.all.map { BusRegionEntity(id: $0.storageKey, name: $0.displayName) }
    }
    func entities(for identifiers: [String]) async throws -> [BusRegionEntity] {
        all.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [BusRegionEntity] { all }
    func defaultResult() -> BusRegionEntity? { all.first { $0.id == "City:Taipei" } }
}

/// 捷運系統。id = MetroOperator.rawValue。
struct MetroSystemEntity: AppEntity {
    let id: String
    let name: String
    var op: MetroOperator { MetroOperator(rawValue: id) ?? .trtc }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "捷運系統" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = MetroSystemEntityQuery()
}

struct MetroSystemEntityQuery: EntityQuery {
    private var all: [MetroSystemEntity] {
        MetroOperator.allCases.map { MetroSystemEntity(id: $0.rawValue, name: $0.displayName) }
    }
    func entities(for identifiers: [String]) async throws -> [MetroSystemEntity] {
        all.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [MetroSystemEntity] { all }
    func defaultResult() -> MetroSystemEntity? { all.first }
}

/// YouBike 縣市。id = BikeCity.rawValue。
struct BikeCityEntity: AppEntity {
    let id: String
    let name: String
    var city: BikeCity { BikeCity(rawValue: id) ?? .taipei }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "縣市" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = BikeCityEntityQuery()
}

struct BikeCityEntityQuery: EntityQuery {
    private var all: [BikeCityEntity] {
        BikeCity.allCases.map { BikeCityEntity(id: $0.rawValue, name: $0.displayName) }
    }
    func entities(for identifiers: [String]) async throws -> [BikeCityEntity] {
        all.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [BikeCityEntity] { all }
    func defaultResult() -> BikeCityEntity? { all.first }
}

// MARK: - Configuration

struct TimetableConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "時刻表" }
    static var description: IntentDescription {
        IntentDescription("顯示指定路線／車站的下幾班車或即時資訊。點下方欄位用選單挑選即可。")
    }

    @Parameter(title: "類型", default: .railTRA)
    var kind: TimetableKind

    // Rail
    @Parameter(title: "起站")
    var railOrigin: RailStationEntity?
    @Parameter(title: "到站")
    var railDestination: RailStationEntity?

    // Bus
    @Parameter(title: "路線號碼", description: "例如 307、1819")
    var busRoute: String?
    @Parameter(title: "站牌名稱", description: "例如 捷運市政府站")
    var busStopName: String?
    @Parameter(title: "地區")
    var busRegion: BusRegionEntity?
    @Parameter(title: "方向", default: .outbound)
    var busDirection: BusDirectionOption

    // Metro
    @Parameter(title: "捷運系統")
    var metroSystem: MetroSystemEntity?

    // Bike
    @Parameter(title: "YouBike 縣市")
    var bikeCity: BikeCityEntity?

    // Metro + Bike station name
    @Parameter(title: "車站名稱", description: "捷運或 YouBike 站名")
    var stationName: String?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$kind) {
            Case(TimetableKind.railTRA) {
                Summary("台鐵　\(\.$railOrigin) 到 \(\.$railDestination)")
            }
            Case(TimetableKind.railTHSR) {
                Summary("高鐵　\(\.$railOrigin) 到 \(\.$railDestination)")
            }
            Case(TimetableKind.busStop) {
                Summary("公車　\(\.$busRoute) 在 \(\.$busStopName)") {
                    \.$busRegion
                    \.$busDirection
                }
            }
            Case(TimetableKind.metro) {
                Summary("捷運　\(\.$metroSystem)　\(\.$stationName)")
            }
            Case(TimetableKind.bike) {
                Summary("YouBike　\(\.$bikeCity)　\(\.$stationName)")
            }
            DefaultCase {
                Summary("時刻表　\(\.$kind)")
            }
        }
    }
}

// MARK: - Timeline

struct TimetableEntry: TimelineEntry {
    let date: Date
    let title: String
    let subtitle: String
    let rows: [Row]
    var kind: TimetableKind = .railTRA

    struct Row: Identifiable {
        let id = UUID()
        let time: String
        let detail: String
    }
}

extension TimetableKind {
    var tint: Color {
        switch self {
        case .railTRA: return .blue
        case .railTHSR: return .orange
        case .busStop: return .green
        case .metro: return .indigo
        case .bike: return .mint
        }
    }
    var symbol: String {
        switch self {
        case .railTRA, .railTHSR: return "tram.fill"
        case .busStop: return "bus.fill"
        case .metro: return "tram.circle.fill"
        case .bike: return "bicycle"
        }
    }
}

struct TimetableProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimetableEntry {
        TimetableEntry(date: .now, title: "台北 → 板橋", subtitle: "台鐵",
                       rows: [.init(time: "08:12", detail: "區間"), .init(time: "08:25", detail: "自強")])
    }

    func snapshot(for configuration: TimetableConfigIntent, in context: Context) async -> TimetableEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: TimetableConfigIntent, in context: Context) async -> Timeline<TimetableEntry> {
        let entry = await entry(for: configuration)
        let refresh: Double
        switch configuration.kind {
        case .busStop, .metro, .bike: refresh = 600
        default: refresh = 900
        }
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refresh)))
    }

    private func entry(for config: TimetableConfigIntent) async -> TimetableEntry {
        var e: TimetableEntry
        switch config.kind {
        case .railTRA, .railTHSR: e = await railEntry(config)
        case .busStop:            e = await busEntry(config)
        case .metro:              e = await metroEntry(config)
        case .bike:               e = await bikeEntry(config)
        }
        e.kind = config.kind
        return e
    }

    // MARK: Rail

    private func railEntry(_ config: TimetableConfigIntent) async -> TimetableEntry {
        let system: RailSystem = config.kind == .railTRA ? .tra : .thsr
        guard let o = config.railOrigin, let d = config.railDestination else {
            return .init(date: .now, title: "尚未設定", subtitle: "長按小工具 → 選起訖站", rows: [])
        }
        let from = RailStation(id: o.stationID, name: o.name)
        let to = RailStation(id: d.stationID, name: d.name)
        do {
            let runs = try await RailService.shared.timetable(system: system, from: from, to: to, date: .now)
            let upcoming = filterUpcoming(runs)
            return .init(
                date: .now,
                title: "\(from.name) → \(to.name)",
                subtitle: system.displayName,
                rows: upcoming.prefix(4).map {
                    .init(time: "\($0.departure)→\($0.arrival)",
                          detail: $0.trainType.isEmpty ? $0.trainNo : $0.trainType)
                }
            )
        } catch {
            return .init(date: .now, title: "\(from.name) → \(to.name)", subtitle: "查詢失敗", rows: [])
        }
    }

    // MARK: Bus

    private func busEntry(_ config: TimetableConfigIntent) async -> TimetableEntry {
        let route = config.busRoute?.trimmingCharacters(in: .whitespaces) ?? ""
        let stopName = config.busStopName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !route.isEmpty, !stopName.isEmpty else {
            return .init(date: .now, title: "尚未設定", subtitle: "長按小工具 → 填路線與站牌", rows: [])
        }
        let scope = config.busRegion?.scope ?? .city(.taipei)
        let dir = config.busDirection.value
        do {
            let dirs = try await BusService.shared.directions(scope: scope, routeName: route)
            let stops = dirs.first { $0.direction == dir }?.stops ?? dirs.first?.stops ?? []
            guard let stop = stops.first(where: { $0.stopName.display.contains(stopName) }) else {
                return .init(date: .now, title: "\(route) · \(stopName)", subtitle: "找不到站牌", rows: [])
            }
            let estimates = try await BusService.shared.estimates(scope: scope, routeName: route)
            let est = estimates["\(dir)-\(stop.stopUID)"]
            return .init(
                date: .now,
                title: "\(route) · \(stop.stopName.display)",
                subtitle: scope.displayName,
                rows: [.init(time: est?.displayText ?? "—", detail: est?.plate ?? "下一班")]
            )
        } catch {
            return .init(date: .now, title: "\(route) · \(stopName)", subtitle: "查詢失敗", rows: [])
        }
    }

    // MARK: Metro

    private func metroEntry(_ config: TimetableConfigIntent) async -> TimetableEntry {
        let name = config.stationName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let op = config.metroSystem?.op, !name.isEmpty else {
            return .init(date: .now, title: "尚未設定", subtitle: "長按小工具 → 選系統與車站", rows: [])
        }
        do {
            let sol = try await MetroService.shared.stationsOfLine(operator: op)
            let allStations = sol.flatMap(\.stations)
            guard let station = allStations.first(where: { $0.name == name })
                    ?? allStations.first(where: { $0.name.contains(name) }) else {
                return .init(date: .now, title: name, subtitle: op.displayName + "・找不到車站", rows: [])
            }
            let board = try await MetroService.shared.liveBoard(operator: op, stationID: station.stationID)
            let rows = board.prefix(4).map {
                TimetableEntry.Row(time: $0.etaText, detail: $0.headingText)
            }
            return .init(date: .now, title: station.name, subtitle: op.displayName, rows: Array(rows))
        } catch {
            return .init(date: .now, title: name, subtitle: op.displayName + "・查詢失敗", rows: [])
        }
    }

    // MARK: Bike

    private func bikeEntry(_ config: TimetableConfigIntent) async -> TimetableEntry {
        let name = config.stationName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let city = config.bikeCity?.city, !name.isEmpty else {
            return .init(date: .now, title: "尚未設定", subtitle: "長按小工具 → 選縣市與站名", rows: [])
        }
        do {
            let stations: [BikeStation] = try await TDXClient.shared.get(
                "v2/Bike/Station/City/\(city.rawValue)",
                query: ["$filter": "contains(StationName/Zh_tw,'\(name.replacingOccurrences(of: "'", with: "''"))')",
                        "$top": "5"]
            )
            guard let station = stations.first else {
                return .init(date: .now, title: name, subtitle: city.displayName + "・找不到站點", rows: [])
            }
            let a = try await BikeService.shared.availability(city: city, stationUID: station.stationUID)
            let d = a?.availableRentBikesDetail
            return .init(
                date: .now,
                title: station.name,
                subtitle: city.displayName,
                rows: [
                    .init(time: "\(a?.availableRentBikes ?? 0)", detail: "可借（一般 \(d?.generalBikes ?? 0)／電動 \(d?.electricBikes ?? 0)）"),
                    .init(time: "\(a?.availableReturnBikes ?? 0)", detail: "可還"),
                ]
            )
        } catch {
            return .init(date: .now, title: name, subtitle: city.displayName + "・查詢失敗", rows: [])
        }
    }

    private func filterUpcoming(_ runs: [TrainRun]) -> [TrainRun] {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let now = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
        let up = runs.filter { $0.departure >= now }
        return up.isEmpty ? runs : up
    }
}

// MARK: - Widget

struct TimetableWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "tw.yayalin.TransitGo.Timetable",
            intent: TimetableConfigIntent.self,
            provider: TimetableProvider()
        ) { entry in
            TimetableWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("時刻表")
        .description("下一班車幾點到。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TimetableWidgetView: View {
    let entry: TimetableEntry
    @Environment(\.widgetFamily) private var family

    private var maxRows: Int { family == .systemSmall ? 3 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbol)
                    .font(.caption.bold())
                    .foregroundStyle(entry.kind.tint)
                Text(entry.subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.kind.tint)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(entry.title)
                .font(family == .systemSmall ? .subheadline.bold() : .headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)

            Rectangle().fill(entry.kind.tint.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 6)

            if entry.rows.isEmpty {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("—").font(.title2.bold()).foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: family == .systemSmall ? 5 : 7) {
                    ForEach(Array(entry.rows.prefix(maxRows).enumerated()), id: \.element.id) { idx, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.time)
                                .font(.callout.monospacedDigit().weight(.bold))
                                .foregroundStyle(idx == 0 ? entry.kind.tint : .primary)
                            Spacer(minLength: 4)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
