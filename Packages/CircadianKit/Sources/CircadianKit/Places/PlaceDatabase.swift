import Foundation

/// Searchable, offline database of airports.
///
/// Loaded once from the bundled `airports.json`. Deliberately not backed by CoreLocation
/// or a web service: a jet-lag plan must be buildable on a plane with no signal, and
/// picking a real airport gives an exact IANA zone and exact coordinates without ever
/// asking for a location permission.
public final class PlaceDatabase: Sendable {

    public static let shared = PlaceDatabase()

    public let places: [Place]
    private let byIATA: [String: Place]

    public init(places: [Place]) {
        self.places = places
        self.byIATA = Dictionary(places.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private convenience init() {
        let loaded: [Place]
        if let url = Bundle.module.url(forResource: "airports", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            loaded = decoded
        } else {
            // A tiny built-in fallback keeps the app usable (and tests meaningful) even if
            // the resource fails to load.
            loaded = PlaceDatabase.fallbackPlaces
        }
        self.init(places: loaded)
    }

    public func place(iata: String) -> Place? {
        byIATA[iata.uppercased()]
    }

    /// Fuzzy search over IATA code, city, airport name and country.
    ///
    /// Ranking, best first: exact IATA match, IATA prefix, city prefix, city substring,
    /// name substring. Hubs outrank regional fields at equal relevance.
    public func search(_ query: String, limit: Int = 40) -> [Place] {
        let q = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !q.isEmpty else {
            return Array(places.lazy.filter(\.isMajor).prefix(limit))
        }

        func score(_ place: Place) -> Int? {
            let iata = place.iata.lowercased()
            let city = place.city.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let name = place.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let country = place.country.lowercased()

            if iata == q { return 0 }
            if iata.hasPrefix(q) { return 1 }
            if city.hasPrefix(q) { return 2 }
            if name.hasPrefix(q) { return 3 }
            if city.contains(q) { return 4 }
            if name.contains(q) { return 5 }
            if country == q { return 6 }
            return nil
        }

        return places
            .compactMap { place -> (Place, Int)? in
                guard let s = score(place) else { return nil }
                // Hubs win ties; the doubling keeps relevance dominant over prominence.
                return (place, s * 2 + (place.isMajor ? 0 : 1))
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.city < rhs.0.city
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Nearest place to a coordinate, using great-circle distance. Used only to offer a
    /// sensible default origin when the host app already knows where the user is.
    public func nearest(latitude: Double, longitude: Double, majorOnly: Bool = true) -> Place? {
        let candidates = majorOnly ? places.filter(\.isMajor) : places
        return candidates.min { a, b in
            haversine(latitude, longitude, a.latitude, a.longitude)
                < haversine(latitude, longitude, b.latitude, b.longitude)
        }
    }

    private func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    static let fallbackPlaces: [Place] = [
        Place(iata: "LHR", name: "London Heathrow", city: "London", country: "GB",
              latitude: 51.4706, longitude: -0.4619, timeZoneIdentifier: "Europe/London", isMajor: true),
        Place(iata: "JFK", name: "John F Kennedy International Airport", city: "New York", country: "US",
              latitude: 40.6398, longitude: -73.7789, timeZoneIdentifier: "America/New_York", isMajor: true),
        Place(iata: "NRT", name: "Narita International Airport", city: "Tokyo", country: "JP",
              latitude: 35.7647, longitude: 140.386, timeZoneIdentifier: "Asia/Tokyo", isMajor: true),
        Place(iata: "LAX", name: "Los Angeles International Airport", city: "Los Angeles", country: "US",
              latitude: 33.9425, longitude: -118.408, timeZoneIdentifier: "America/Los_Angeles", isMajor: true),
        Place(iata: "SYD", name: "Sydney Kingsford Smith", city: "Sydney", country: "AU",
              latitude: -33.9461, longitude: 151.177, timeZoneIdentifier: "Australia/Sydney", isMajor: true)
    ]
}
