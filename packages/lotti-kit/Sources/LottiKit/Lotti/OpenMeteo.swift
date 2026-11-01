import Foundation

/// Weather from Open-Meteo (free, no key; WeatherKit needs a paid developer account).
public enum OpenMeteo {
    public static func url(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", latitude)),
            .init(name: "longitude", value: String(format: "%.3f", longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "precipitation,precipitation_probability"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        return components.url!
    }

    struct Response: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
        }
        struct Hourly: Decodable {
            var time: [TimeInterval]
            var precipitation: [Double?]
            var precipitation_probability: [Int?]
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double?]
            var temperature_2m_min: [Double?]
        }
        var current: Current
        var hourly: Hourly?
        var daily: Daily?
    }

    /// Parses a forecast. Rain "from" is the first hour from now on with at least 0.3 mm or a
    /// 60 % chance.
    public static func weather(from data: Data, now: Date) throws -> Weather {
        let r = try JSONDecoder().decode(Response.self, from: data)
        var rainFrom: Date?
        if let hourly = r.hourly {
            for (i, time) in hourly.time.enumerated() where time + 3600 > now.timeIntervalSince1970 {
                let mm = hourly.precipitation[safe: i] ?? nil
                let chance = hourly.precipitation_probability[safe: i] ?? nil
                if (mm ?? 0) >= 0.3 || (chance ?? 0) >= 60 {
                    rainFrom = Date(timeIntervalSince1970: max(time, now.timeIntervalSince1970))
                    break
                }
            }
        }
        return Weather(
            temperature: Int(r.current.temperature_2m.rounded()),
            condition: condition(r.current.weather_code),
            high: (r.daily?.temperature_2m_max.first ?? nil).map { Int($0.rounded()) },
            low: (r.daily?.temperature_2m_min.first ?? nil).map { Int($0.rounded()) },
            rainFrom: rainFrom)
    }

    /// WMO weather codes in plain words.
    public static func condition(_ code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1: "mostly clear"
        case 2: "partly cloudy"
        case 3: "cloudy"
        case 45, 48: "foggy"
        case 51, 53, 55, 56, 57: "drizzly"
        case 61, 80: "light rain"
        case 63, 81: "rainy"
        case 65, 82: "heavy rain"
        case 66, 67: "freezing rain"
        case 71, 85: "light snow"
        case 73, 75, 77, 86: "snowy"
        case 95, 96, 99: "stormy"
        default: "mixed"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
