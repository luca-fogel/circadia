import Testing
import Foundation
@testable import CircadianKit

@Suite("Solar position")
struct SolarPositionTests {

    func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: c)!
    }

    @Test("Day length at an equinox is close to 12 hours everywhere")
    func equinoxDayLength() {
        // Equinox day length is ~12 h at all latitudes; refraction and the solar disc make
        // it a few minutes longer, and the excess grows with latitude.
        let cases: [(String, Double, Double)] = [
            ("Africa/Nairobi", -1.29, 36.82),
            ("Europe/London", 51.5, -0.13),
            ("America/New_York", 40.71, -74.0),
            ("Australia/Sydney", -33.87, 151.21)
        ]
        for (tz, lat, lon) in cases {
            let day = SolarDay(
                localDay: utc(2026, 3, 20),
                latitude: lat, longitude: lon,
                timeZone: TimeZone(identifier: tz)!
            )
            let hours = day.daylightHours
            #expect(hours > 12.0 && hours < 12.4, "\(tz): \(hours) h")
        }
    }

    @Test("Sunrise and sunset are symmetric about solar noon")
    func symmetricAboutSolarNoon() {
        let day = SolarDay(
            localDay: utc(2026, 8, 25),
            latitude: 42.36, longitude: -71.06,
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        let sunrise = try! #require(day.sunrise)
        let sunset = try! #require(day.sunset)
        let before = day.solarNoon.timeIntervalSince(sunrise)
        let after = sunset.timeIntervalSince(day.solarNoon)
        #expect(abs(before - after) < 60, "asymmetry of \(abs(before - after)) s")
    }

    @Test("Summer days are longer than winter days in the northern hemisphere, and reversed in the south")
    func seasonalityHasTheRightSign() {
        let london = (51.5, -0.13, TimeZone(identifier: "Europe/London")!)
        let june = SolarDay(localDay: utc(2026, 6, 21), latitude: london.0, longitude: london.1, timeZone: london.2)
        let december = SolarDay(localDay: utc(2026, 12, 21), latitude: london.0, longitude: london.1, timeZone: london.2)
        #expect(june.daylightHours > 16)
        #expect(december.daylightHours < 8.5)

        let sydney = (-33.87, 151.21, TimeZone(identifier: "Australia/Sydney")!)
        let sydneyJune = SolarDay(localDay: utc(2026, 6, 21), latitude: sydney.0, longitude: sydney.1, timeZone: sydney.2)
        let sydneyDecember = SolarDay(localDay: utc(2026, 12, 21), latitude: sydney.0, longitude: sydney.1, timeZone: sydney.2)
        #expect(sydneyDecember.daylightHours > sydneyJune.daylightHours)
    }

    @Test("Polar day and polar night are detected above the Arctic Circle")
    func polarCases() {
        let tromso = (69.65, 18.96, TimeZone(identifier: "Europe/Oslo")!)
        let midsummer = SolarDay(localDay: utc(2026, 6, 21), latitude: tromso.0, longitude: tromso.1, timeZone: tromso.2)
        #expect(midsummer.isPolarDay)
        #expect(!midsummer.isPolarNight)
        #expect(midsummer.daylightHours == 24)

        let midwinter = SolarDay(localDay: utc(2026, 12, 21), latitude: tromso.0, longitude: tromso.1, timeZone: tromso.2)
        #expect(midwinter.isPolarNight)
        #expect(midwinter.daylightHours == 0)
        #expect(midwinter.daylight == nil)
    }

    @Test("Solar noon lands near local clock noon, offset by longitude within the zone")
    func solarNoonIsNearClockNoon() {
        // Greenwich in winter, on the prime meridian and on UTC: solar noon within a
        // quarter of an hour of 12:00 (the equation of time is the only slack).
        let tz = TimeZone(identifier: "Europe/London")!
        let noon = SolarPosition.solarNoon(onLocalDay: utc(2026, 1, 15), longitude: 0, timeZone: tz)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let components = cal.dateComponents([.hour, .minute], from: noon)
        let minutesFromNoon = abs((components.hour! * 60 + components.minute!) - 720)
        #expect(minutesFromNoon < 15, "solar noon was \(minutesFromNoon) min from clock noon")
    }

    @Test("Elevation is negative at midnight and positive at midday")
    func elevationSignFollowsTheClock() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 0))!
        let midday = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 13))!
        #expect(SolarPosition.elevation(at: midnight, latitude: 51.5, longitude: -0.13) < 0)
        #expect(SolarPosition.elevation(at: midday, latitude: 51.5, longitude: -0.13) > 40)
    }

    @Test("Civil twilight brackets sunrise and sunset")
    func twilightBracketsDaylight() {
        let day = SolarDay(
            localDay: utc(2026, 4, 10),
            latitude: 48.86, longitude: 2.35,
            timeZone: TimeZone(identifier: "Europe/Paris")!
        )
        let dawn = try! #require(day.civilDawn)
        let dusk = try! #require(day.civilDusk)
        let sunrise = try! #require(day.sunrise)
        let sunset = try! #require(day.sunset)
        #expect(dawn < sunrise)
        #expect(dusk > sunset)
        #expect(try! #require(day.usableLight).durationHours > day.daylightHours)
    }
}
