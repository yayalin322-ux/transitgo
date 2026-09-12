import Foundation

/// Current weather at a coordinate, via Open-Meteo (free, no API key). App-only —
/// Home is the only place this is used.
struct WeatherInfo {
    let tempC: Double
    let code: Int
    let isDay: Bool

    /// SF Symbol for the WMO weather code (https://open-meteo.com/en/docs — "weather_code").
    var symbolName: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var description: String {
        switch code {
        case 0: return "晴朗"
        case 1: return "多雲時晴"
        case 2: return "多雲"
        case 3: return "陰天"
        case 45, 48: return "有霧"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65: return "下雨"
        case 66, 67: return "凍雨"
        case 71, 73, 75, 77: return "下雪"
        case 80, 81, 82: return "陣雨"
        case 85, 86: return "陣雪"
        case 95, 96, 99: return "雷雨"
        default: return "—"
        }
    }
}

enum WeatherService {
    private struct Response: Decodable {
        let current: Current
        struct Current: Decodable {
            let temperature2m: Double
            let weatherCode: Int
            let isDay: Int
            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }
    }

    static func current(lat: Double, lon: Double) async -> WeatherInfo? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "Asia/Taipei"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return WeatherInfo(tempC: decoded.current.temperature2m, code: decoded.current.weatherCode,
                           isDay: decoded.current.isDay == 1)
    }
}
