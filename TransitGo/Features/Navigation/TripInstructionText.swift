import Foundation

/// The only place navigation state becomes words. `TripEngine` produces data; screens ask this for text, so wording
/// can change (or be localized) without touching the logic, and no engine code carries UI strings.
enum TripInstructionText {
    private static func minutes(_ seconds: Int?) -> String? {
        guard let seconds else { return nil }
        return "約 \(max(1, Int((Double(seconds) / 60).rounded()))) 分鐘"
    }
    private static func meters(_ m: Double?) -> String? {
        guard let m else { return nil }
        return m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000)
    }
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "zh_Hant_TW"); f.timeZone = TimeZone(identifier: "Asia/Taipei"); return f
    }()
    static func clockText(_ d: Date) -> String { clock.string(from: d) }

    static func icon(_ kind: TripLegKind) -> String {
        switch kind {
        case .walk: return "🚶"
        case .bus: return "🚌"
        case .metro: return "🚇"
        case .tra: return "🚆"
        case .hsr: return "🚄"
        case .bike: return "🚲"
        case .other: return "➡️"
        }
    }

    private static func line(_ i: TripInstruction) -> String {
        let name: String
        switch i.legKind {
        case .bus: name = "公車 " + (i.lineLabel ?? "")
        case .metro: name = i.lineLabel ?? "捷運"
        case .tra: name = "台鐵" + (i.lineLabel.map { " \($0)" } ?? "")
        case .hsr: name = "高鐵"
        default: name = i.lineLabel ?? ""
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Headline of a step, e.g. "🚶 前往新竹車站".
    static func title(_ i: TripInstruction) -> String {
        let icon = icon(i.legKind)
        switch i.kind {
        case .walkTo: return "\(icon) 前往\(i.targetName ?? "")"
        case .approaching: return "\(icon) 即將抵達\(i.targetName ?? "")"
        case .transfer: return "\(icon) 前往\(i.targetName ?? "")轉乘"
        case .waitForVehicle: return "\(icon) 搭乘 \(line(i))"
        case .rideVehicle: return "\(icon) 乘坐 \(line(i))"
        case .prepareToAlight: return "\(icon) 即將抵達\(i.targetName ?? "")，請準備下車"
        case .rentBike: return "\(icon) 在\(i.targetName ?? "")借車"
        case .rideBike: return "\(icon) 騎往\(i.targetName ?? "")"
        case .returnBike: return "\(icon) 即將抵達\(i.targetName ?? "")，請準備還車"
        case .arrived: return "🏁 已抵達\(i.targetName ?? "目的地")"
        case .staticOverview: return "\(icon) \(line(i).isEmpty ? (i.targetName ?? "") : line(i))"
        }
    }

    /// Detail lines under the headline (distance, time, stops, delay, where the figure comes from).
    static func details(_ i: TripInstruction) -> [String] {
        var out: [String] = []
        switch i.kind {
        case .walkTo, .approaching, .transfer:
            if let d = meters(i.distanceMeters) { out.append(d) }
            if let t = minutes(i.durationSeconds) { out.append(t) }
        case .waitForVehicle:
            if let towards = i.towards { out.append(towards) }
            if let time = i.time { out.append("\(clockText(time)) 出發" + sourceSuffix(i)) }
            if let delay = i.delaySeconds, delay >= TripPolicy.delayAlertSeconds { out.append("⚠️ 延誤 \(Int((Double(delay) / 60).rounded())) 分鐘") }
        case .rideVehicle, .prepareToAlight:
            if let towards = i.towards { out.append(towards) }
            if let cur = i.currentStopName { out.append("目前約在：\(cur)") }
            if let next = i.nextStopName, i.kind == .rideVehicle { out.append("下一站：\(next)") }
            if let stops = i.stopsRemaining { out.append("還有\(i.stopsAreEstimated ? "約 " : "") \(stops) 站") }
            if let time = i.time { out.append("預計 \(clockText(time)) 抵達" + sourceSuffix(i)) }
            if let delay = i.delaySeconds, delay >= TripPolicy.delayAlertSeconds { out.append("⚠️ 延誤 \(Int((Double(delay) / 60).rounded())) 分鐘") }
        case .rentBike:
            out.append("到站後刷卡借車")
        case .rideBike, .returnBike:
            if let d = meters(i.distanceMeters) { out.append(d) }
            if let t = minutes(i.durationSeconds) { out.append("騎乘\(t)") }
        case .arrived, .staticOverview:
            if i.kind == .staticOverview, let time = i.time { out.append("預定 \(clockText(time))" + "（未開啟定位，無法即時跟隨）") }
        }
        return out
    }

    /// Where a shown time comes from — realtime first, else the timetable, and never a guess dressed as either.
    static func sourceSuffix(_ i: TripInstruction) -> String {
        switch i.source {
        case .realtime: return "（即時）"
        case .schedule: return "（依時刻表）"
        case .estimate: return "（預估）"
        case .gps: return ""
        }
    }

    /// "下一步" line for the preview.
    static func nextLine(_ i: TripInstruction) -> String {
        switch i.kind {
        case .waitForVehicle:
            let when = i.time.map { "・\(clockText($0)) 出發" } ?? ""
            return "\(title(i))\(i.towards.map { "・\($0)" } ?? "")\(when)"
        case .walkTo, .transfer:
            return "\(title(i))" + (meters(i.distanceMeters).map { "・\($0)" } ?? "")
        default: return title(i)
        }
    }

    static func transferLine(_ t: TripTransfer) -> String {
        "轉乘 \(t.lineLabel ?? "")（\(t.atName)）"
    }

    /// Notice text for an event worth showing in the app (nil = nothing to show).
    static func banner(for event: TripEvent, session: TripSession) -> String? {
        switch event {
        case .approachingStop(_, let name): return "即將抵達\(name)"
        case .arrivedAtStation(_, let name, _): return "已抵達\(name)"
        case .transferRequired(_, _, let name): return "即將轉乘：\(name)"
        case .delayed(_, let seconds): return "⚠️ 延誤 \(Int((Double(seconds) / 60).rounded())) 分鐘"
        case .missedDeparture: return "已錯過此班次，正在尋找下一班…"
        case .rerouteSuggested(let reason): return reason == .cancelled ? "此班次已取消，可以重新規劃" : "嚴重延誤，可以重新規劃"
        case .rerouted: return "已依目前位置重新規劃"
        case .offline: return "目前無網路，使用最近一次路線資料"
        case .backOnline: return "已恢復連線"
        case .completed: return "已抵達目的地"
        case .offRoute: return "你似乎偏離了路線，正在重新規劃…"
        default: return nil
        }
    }
}
