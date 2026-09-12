import Foundation

/// Taipei City's own "train entering platform" feed (data.taipei, updated every ~30s),
/// covering TRTC's Wenshan/Tamsui-Xinyi/Songshan-Xindian/Zhonghe-Xinlu/Bannan lines.
/// It's an *event* feed ("a train to X just entered station Y"), not an ETA table, so it
/// complements TDX's LiveBoard rather than replacing it — a matching, recent row means
/// "this one is entering right now" with tighter latency than TDX's own estimate.
enum TaipeiMetroLiveFeed {
    private struct Row: Decodable {
        let station: String
        let destination: String
        let updateTime: String   // "yyyyMMddHHmmss"

        enum CodingKeys: String, CodingKey {
            case station = "Station"
            case destination = "Destination"
            case updateTime = "UpdateTime"
        }
    }

    private static let url = URL(string: "https://tcgmetro.blob.core.windows.net/stationnames/stations.json")!
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }()

    /// Destination names (station suffix "站" stripped, as TDX's own names usually are)
    /// currently reported entering `stationName`'s platform, within the last 90s.
    static func enteringNow(stationName: String) async -> Set<String> {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        let target = normalized(stationName)
        let cutoff = Date().addingTimeInterval(-90)
        var out = Set<String>()
        for row in rows where normalized(row.station) == target {
            guard let t = formatter.date(from: row.updateTime), t > cutoff else { continue }
            out.insert(normalized(row.destination))
        }
        return out
    }

    private static func normalized(_ s: String) -> String {
        s.hasSuffix("站") ? String(s.dropLast()) : s
    }
}
