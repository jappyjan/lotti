import Foundation
import Testing
@testable import LottiKit

struct OpenMeteoTests {
    @Test func parsesCurrentDailyAndRain() throws {
        let json = """
            {"current":{"time":1793520000,"temperature_2m":11.6,"weather_code":3},
             "hourly":{"time":[1793516400,1793520000,1793523600,1793527200],
                       "precipitation":[0.5,0.0,0.1,0.8],"precipitation_probability":[70,10,20,80]},
             "daily":{"time":[1793487600,1793574000],"weather_code":[3,61],"temperature_2m_max":[14.2,10.4],"temperature_2m_min":[6.8,5.1],
                      "precipitation_probability_max":[80,null]}}
            """
        let weather = try OpenMeteo.weather(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1793520600))
        #expect(weather == Weather(temperature: 12, condition: "cloudy", high: 14, low: 7,
                                   rainFrom: Date(timeIntervalSince1970: 1793527200),
                                   days: [
                                       DayForecast(date: Date(timeIntervalSince1970: 1793487600), condition: "cloudy",
                                                   high: 14, low: 7, rainChance: 80),
                                       DayForecast(date: Date(timeIntervalSince1970: 1793574000), condition: "light rain",
                                                   high: 10, low: 5),
                                   ]))
        #expect(weather.tomorrow?.condition == "light rain")
    }

    @Test func urlAsksForWhatWeUse() {
        let url = OpenMeteo.url(latitude: 52.52, longitude: 13.405).absoluteString
        #expect(url.contains("latitude=52.520"))
        #expect(url.contains("current=temperature_2m,weather_code"))
    }
}
