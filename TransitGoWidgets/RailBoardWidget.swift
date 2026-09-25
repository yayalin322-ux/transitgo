import SwiftUI
import WidgetKit
import AppIntents

// A station's departure board: pick ONE station, see every train heading 北上 and 南下 with where it is going.
// No destination station to choose. Data: the backend's /v1/rail/board (one shared TDX read for every device).

struct RailBoardConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "車站看板" }
    static var description: IntentDescription {
        IntentDescription("選一個台鐵車站，顯示北上、南下所有列車和開往哪裡。")
    }

    @Parameter(title: "車站")
    var station: TRAStationEntity?

    static var parameterSummary: some ParameterSummary { Summary("台鐵 \(\.$station)") }
}

struct RailBoardEntry: TimelineEntry {
    enum Content {
        case needsStation
        case board(RailBoard)
        case failed(stationName: String?)
    }
    let date: Date
    let content: Content
}

struct RailBoardProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RailBoardEntry {
        RailBoardEntry(date: .now, content: .needsStation)
    }

    func snapshot(for configuration: RailBoardConfigIntent, in context: Context) async -> RailBoardEntry {
        await load(configuration, at: .now)
    }

    func timeline(for configuration: RailBoardConfigIntent, in context: Context) async -> Timeline<RailBoardEntry> {
        let first = await load(configuration, at: .now)
        guard case .board(let board) = first.content else {
            return Timeline(entries: [first], policy: .after(Date().addingTimeInterval(120)))
        }
        // One fetch covers the next half hour: an entry per minute drops trains as they leave, so the widget stays
        // right even if a later refresh is late or fails.
        let entries = (0..<30).map { RailBoardEntry(date: Date().addingTimeInterval(Double($0) * 60), content: .board(board)) }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    private func load(_ config: RailBoardConfigIntent, at date: Date) async -> RailBoardEntry {
        guard let station = config.station else { return RailBoardEntry(date: date, content: .needsStation) }
        do {
            let board = try await RailBoardService.board(stationID: station.id)
            return RailBoardEntry(date: date, content: board.available ? .board(board) : .failed(stationName: station.name))
        } catch {
            return RailBoardEntry(date: date, content: .failed(stationName: station.name))
        }
    }
}

struct RailBoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "tw.yayalin.TransitGo.RailBoard", intent: RailBoardConfigIntent.self, provider: RailBoardProvider()) { entry in
            RailBoardView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("台鐵車站看板")
        .description("選一個車站，看北上、南下所有列車與終點站。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct RailBoardView: View {
    let entry: RailBoardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case .needsStation:
            message("台鐵車站看板", "長按小工具 → 編輯，選一個車站")
        case .failed(let name):
            message(name ?? "台鐵車站看板", "暫時查不到列車資料，稍後會自動重試")
        case .board(let board):
            if family == .accessoryRectangular { lockScreen(board) } else { boardBody(board) }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "tram.fill").font(.headline).foregroundStyle(.blue)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rowsPerColumn: Int {
        switch family { case .systemSmall: 1; case .systemMedium: 3; default: 7 }
    }

    private func boardBody(_ board: RailBoard) -> some View {
        let now = entry.date
        let north = board.north(at: now), south = board.south(at: now)
        let rest = board.rest(at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(board.stationName, systemImage: "tram.fill").font(.subheadline.bold()).foregroundStyle(.blue).lineLimit(1)
                Spacer()
                if board.stale == true { Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.orange) }
            }
            if family == .systemSmall {
                HStack(alignment: .top, spacing: 8) {
                    column("北上", north, now: now, limit: 1, compact: true)
                    column("南下", south, now: now, limit: 1, compact: true)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    column("北上", north, now: now, limit: rowsPerColumn, compact: false)
                    Divider()
                    column("南下", south, now: now, limit: rowsPerColumn, compact: false)
                }
                if !board.headingsKnown || !rest.isEmpty, family == .systemLarge {
                    Text("其他方向：" + rest.prefix(3).map { "\($0.depart) 往\($0.dest)" }.joined(separator: "、"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func column(_ title: String, _ trains: [RailBoardTrain], now: Date, limit: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            Text(title).font(.caption.bold()).foregroundStyle(title == "北上" ? Color.orange : Color.teal)
            if trains.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            ForEach(Array(trains.prefix(limit))) { t in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(t.depart).font((compact ? Font.callout : .subheadline).monospacedDigit().weight(.bold))
                        if let d = t.delayMinutes, d > 0 { Text("+\(d)").font(.caption2.bold()).foregroundStyle(.orange) }
                    }
                    Text("\(t.type.isEmpty ? "" : t.type + " ")往\(t.dest)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lockScreen(_ board: RailBoard) -> some View {
        let now = entry.date
        return VStack(alignment: .leading, spacing: 1) {
            Text(board.stationName).font(.caption.bold())
            ForEach([("北上", board.north(at: now).first), ("南下", board.south(at: now).first)], id: \.0) { label, t in
                Text(t.map { "\(label) \($0.depart) 往\($0.dest)" } ?? "\(label) —").font(.caption2).lineLimit(1)
            }
        }
    }
}
