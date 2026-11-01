import CoreLocation
import EventKit
import Foundation
import LottiKit

/// Today's calendar (EventKit) and weather (Open-Meteo at the phone's location).
actor DeviceToday: TodayProvider {
    private let store = EKEventStore()
    private var calendarAccess: Task<Bool, Never>?
    private var weather: (value: Weather, fetched: Date)?
    private var location: (coordinate: CLLocationCoordinate2D, found: Date)?

    func today(at now: Date) async -> TodayInfo {
        async let events = events(on: now)
        async let weather = currentWeather(now: now)
        return await TodayInfo(now: now, events: events, weather: weather)
    }

    private func events(on now: Date) async -> [CalendarEntry] {
        let start = Calendar.current.startOfDay(for: now)
        return (try? await events(from: start, to: Calendar.current.date(byAdding: .day, value: 1, to: start)!)) ?? []
    }

    /// Events in the calendars you didn't switch off. Throws without calendar access.
    func events(from start: Date, to end: Date) async throws -> [CalendarEntry] {
        if calendarAccess == nil {
            calendarAccess = Task { await self.requestCalendarAccess() }
        }
        guard await calendarAccess?.value == true else { throw ToolError("Lotti has no access to the calendar.") }
        let hidden = Settings.hiddenCalendars
        let calendars = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map {
            CalendarEntry(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                          location: $0.location?.isEmpty == false ? $0.location : nil)
        }
    }

    private func requestCalendarAccess() async -> Bool {
        let allowed = (try? await store.requestFullAccessToEvents()) ?? false
        print("[Today] calendar access: \(allowed)")
        return allowed
    }

    func currentWeather(now: Date) async -> Weather? {
        if let weather, now.timeIntervalSince(weather.fetched) < 20 * 60 { return weather.value }
        // No location, no weather: better nothing than another city's.
        guard let place = await coordinate() else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: OpenMeteo.url(latitude: place.latitude, longitude: place.longitude))
            let value = try OpenMeteo.weather(from: data, now: now)
            weather = (value, now)
            return value
        } catch {
            print("[Today] weather failed: \(error.localizedDescription)")
            return weather?.value
        }
    }

    /// A fresh location fix, falling back to the last known one. Nil if there never was one.
    func freshLocation() async -> CLLocationCoordinate2D? {
        if let location, Date().timeIntervalSince(location.found) < 60 { return location.coordinate }
        if let found = await Self.findLocation() {
            location = (found, Date())
            return found
        }
        return location?.coordinate
    }

    /// Where the phone is, at most 15 minutes old if a new fix can be had. Nil if never known.
    private func coordinate() async -> CLLocationCoordinate2D? {
        if let location, Date().timeIntervalSince(location.found) < 15 * 60 { return location.coordinate }
        if let found = await Self.findLocation() {
            location = (found, Date())
            return found
        }
        return location?.coordinate
    }

    /// One location fix, or nil after a few seconds or without permission.
    @MainActor private static func findLocation() async -> CLLocationCoordinate2D? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        let deadline = Date().addingTimeInterval(8)
        do {
            for try await update in CLLocationUpdate.liveUpdates(.default) {
                if let location = update.location {
                    print("[Today] location found")
                    return location.coordinate
                }
                if update.authorizationDenied || Date() > deadline { break }
            }
        } catch {
            print("[Today] location failed: \(error.localizedDescription)")
        }
        return nil
    }
}
