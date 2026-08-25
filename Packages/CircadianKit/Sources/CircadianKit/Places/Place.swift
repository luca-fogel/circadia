import Foundation

/// A geographic endpoint of a flight: an airport, with everything the engine needs to
/// reason about its clock and its daylight.
public struct Place: Hashable, Sendable, Codable, Identifiable {
    /// IATA code, e.g. `LHR`. Unique within the bundled database.
    public var iata: String
    public var name: String
    public var city: String
    /// ISO 3166-1 alpha-2 country code.
    public var country: String
    public var latitude: Double
    public var longitude: Double
    /// IANA time zone identifier, e.g. `Europe/London`.
    ///
    /// Storing the identifier — not a fixed UTC offset — is what makes daylight saving
    /// transitions correct: the offset is resolved against the specific instant.
    public var timeZoneIdentifier: String
    /// Whether this is a significant hub, used to rank search results.
    public var isMajor: Bool

    public var id: String { iata }

    public init(
        iata: String,
        name: String,
        city: String,
        country: String,
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String,
        isMajor: Bool = false
    ) {
        self.iata = iata
        self.name = name
        self.city = city
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isMajor = isMajor
    }

    enum CodingKeys: String, CodingKey {
        case iata, name, city, country
        case latitude = "lat"
        case longitude = "lon"
        case timeZoneIdentifier = "tz"
        case isMajor = "major"
    }

    /// Resolved time zone, falling back to GMT if the identifier is unknown to the
    /// platform (possible if the bundled data outruns the OS's tzdata).
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// A calendar in this place's zone, for building local wall-clock times.
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// UTC offset in hours *at a specific instant*, so DST is accounted for.
    public func utcOffsetHours(at date: Date) -> Double {
        Double(timeZone.secondsFromGMT(for: date)) / 3600
    }

    /// Daylight structure of the local day containing `date`.
    public func solarDay(containing date: Date) -> SolarDay {
        SolarDay(
            localDay: date,
            latitude: latitude,
            longitude: longitude,
            timeZone: timeZone
        )
    }

    public var displayName: String { "\(city) (\(iata))" }

    /// `true` if this place observes DST at any point in the year containing `date`.
    public func observesDST(inYearOf date: Date) -> Bool {
        timeZone.nextDaylightSavingTimeTransition(after: date.addingTimeInterval(-365 * 86400)) != nil
    }
}
