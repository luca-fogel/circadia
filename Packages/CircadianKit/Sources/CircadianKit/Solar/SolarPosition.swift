import Foundation

/// Solar position and daylight boundaries, computed locally.
///
/// Implements the NOAA Solar Calculator formulation of the low-precision algorithms in
/// Meeus, *Astronomical Algorithms* (2nd ed., ch. 25 and 28). Accuracy is well under a
/// minute for the sunrise/sunset times this engine needs, and it requires no network
/// access, no API key and no location permission — the coordinates come from the place
/// the user picked.
public enum SolarPosition {

    // MARK: - Elevation thresholds

    /// Geometric elevation of the sun's centre at apparent sunrise/sunset, accounting for
    /// atmospheric refraction and the solar radius.
    public static let sunriseElevation: Double = -0.833
    /// Civil twilight: enough light to see outdoors, and already circadian-relevant.
    public static let civilTwilightElevation: Double = -6.0
    /// Elevation above which outdoor light is reliably above the circadian saturation
    /// threshold even under cloud.
    public static let brightDaylightElevation: Double = 10.0

    // MARK: - Core

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Julian day number for an instant.
    static func julianDay(from date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }

    /// Solar geometry for a given instant, independent of the observer.
    struct Geometry {
        /// Solar declination, degrees.
        var declination: Double
        /// Equation of time, minutes.
        var equationOfTime: Double
    }

    static func geometry(julianDay jd: Double) -> Geometry {
        let t = (jd - 2451545.0) / 36525.0

        // Geometric mean longitude and mean anomaly of the Sun.
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        // Equation of the centre.
        let c = sin(radians(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(radians(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(radians(3 * m)) * 0.000289

        let trueLongitude = l0 + c
        // Apparent longitude, correcting for nutation and aberration.
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(radians(omega))

        // Obliquity of the ecliptic, with the nutation correction.
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(radians(omega))

        let declination = degrees(asin(sin(radians(obliquity)) * sin(radians(apparentLongitude))))

        // Equation of time, in minutes.
        let y = pow(tan(radians(obliquity / 2)), 2)
        let eot = 4 * degrees(
            y * sin(radians(2 * l0))
            - 2 * e * sin(radians(m))
            + 4 * e * y * sin(radians(m)) * cos(radians(2 * l0))
            - 0.5 * y * y * sin(radians(4 * l0))
            - 1.25 * e * e * sin(radians(2 * m))
        )

        return Geometry(declination: declination, equationOfTime: eot)
    }

    /// Solar elevation above the horizon, in degrees, at an instant and place.
    public static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let jd = julianDay(from: date)
        let g = geometry(julianDay: jd)

        // True solar time in minutes, then the hour angle.
        let minutesUTC = (jd + 0.5).truncatingRemainder(dividingBy: 1) * 1440
        let trueSolarTime = (minutesUTC + g.equationOfTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let zenithCos = sin(radians(latitude)) * sin(radians(g.declination))
            + cos(radians(latitude)) * cos(radians(g.declination)) * cos(radians(hourAngle))
        return 90 - degrees(acos(min(1, max(-1, zenithCos))))
    }

    // MARK: - Daylight boundaries

    /// The two instants on a given local day at which the sun crosses `elevation`,
    /// or `nil` if it never does (polar day or polar night at that threshold).
    public static func crossings(
        elevation targetElevation: Double,
        onLocalDay day: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone
    ) -> (rising: Date, setting: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: day)
        // Anchor the geometry at local noon, the standard NOAA convention.
        let localNoon = startOfDay.addingTimeInterval(12 * 3600)

        let g = geometry(julianDay: julianDay(from: localNoon))

        let latRad = radians(latitude)
        let decRad = radians(g.declination)
        let cosHourAngle = (sin(radians(targetElevation)) - sin(latRad) * sin(decRad))
            / (cos(latRad) * cos(decRad))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = degrees(acos(cosHourAngle))

        // Minutes after 00:00 UTC of the solar-noon instant and the two crossings.
        let solarNoonUTCMinutes = 720 - 4 * longitude - g.equationOfTime

        // Midnight UTC of the UTC day containing local noon, as the base for the offsets.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcMidnight = utcCalendar.startOfDay(for: localNoon)

        let rising = utcMidnight.addingTimeInterval((solarNoonUTCMinutes - 4 * hourAngle) * 60)
        let setting = utcMidnight.addingTimeInterval((solarNoonUTCMinutes + 4 * hourAngle) * 60)
        return (rising, setting)
    }

    /// Solar noon on a local day.
    public static func solarNoon(
        onLocalDay day: Date,
        longitude: Double,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let localNoon = calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
        let g = geometry(julianDay: julianDay(from: localNoon))

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcMidnight = utcCalendar.startOfDay(for: localNoon)
        return utcMidnight.addingTimeInterval((720 - 4 * longitude - g.equationOfTime) * 60)
    }
}

/// Daylight structure of one local day at one place.
public struct SolarDay: Hashable, Sendable {
    public var sunrise: Date?
    public var sunset: Date?
    public var civilDawn: Date?
    public var civilDusk: Date?
    public var solarNoon: Date

    /// True when the sun stays above the sunrise threshold for the whole day.
    public var isPolarDay: Bool
    /// True when the sun never reaches the sunrise threshold.
    public var isPolarNight: Bool

    /// The interval during which the sun is up, if it rises and sets normally.
    public var daylight: TimeWindow? {
        guard let sunrise, let sunset, sunrise < sunset else { return nil }
        return TimeWindow(start: sunrise, end: sunset)
    }

    /// Daylight widened to civil twilight — the window in which outdoor light is still
    /// bright enough to matter circadianly.
    public var usableLight: TimeWindow? {
        guard let dawn = civilDawn, let dusk = civilDusk, dawn < dusk else { return nil }
        return TimeWindow(start: dawn, end: dusk)
    }

    public var daylightHours: Double {
        if isPolarDay { return 24 }
        if isPolarNight { return 0 }
        return daylight?.durationHours ?? 0
    }

    public init(
        localDay: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone
    ) {
        self.solarNoon = SolarPosition.solarNoon(
            onLocalDay: localDay, longitude: longitude, timeZone: timeZone
        )

        let sun = SolarPosition.crossings(
            elevation: SolarPosition.sunriseElevation,
            onLocalDay: localDay, latitude: latitude, longitude: longitude, timeZone: timeZone
        )
        let civil = SolarPosition.crossings(
            elevation: SolarPosition.civilTwilightElevation,
            onLocalDay: localDay, latitude: latitude, longitude: longitude, timeZone: timeZone
        )

        self.sunrise = sun?.rising
        self.sunset = sun?.setting
        self.civilDawn = civil?.rising
        self.civilDusk = civil?.setting

        if sun == nil {
            // No crossing: decide which side of the horizon we are stuck on.
            let noonElevation = SolarPosition.elevation(
                at: solarNoon, latitude: latitude, longitude: longitude
            )
            self.isPolarDay = noonElevation > SolarPosition.sunriseElevation
            self.isPolarNight = !self.isPolarDay
        } else {
            self.isPolarDay = false
            self.isPolarNight = false
        }
    }
}
