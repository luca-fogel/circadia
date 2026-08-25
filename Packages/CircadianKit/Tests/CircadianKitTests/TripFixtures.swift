import Foundation
@testable import CircadianKit

/// Shared trip builders so the scenario tests read as itineraries rather than as date maths.
enum Fixture {

    static let db = PlaceDatabase.shared

    static func place(_ iata: String) -> Place {
        db.place(iata: iata) ?? PlaceDatabase.fallbackPlaces.first { $0.iata == iata }!
    }

    static let lhr = place("LHR")
    static let jfk = place("JFK")
    static let nrt = place("NRT")
    static let lax = place("LAX")
    static let syd = place("SYD")
    static let cdg = place("CDG")
    static let dub = place("DUB")

    /// Builds a leg from local wall-clock departure plus a block time, which is how a
    /// traveller actually reads a booking.
    static func leg(
        _ origin: Place,
        _ destination: Place,
        departLocal: DateComponents,
        blockHours: Double
    ) -> Flight {
        let departure = origin.calendar.date(from: departLocal)!
        return Flight(
            origin: origin,
            destination: destination,
            departure: departure,
            arrival: departure.addingTimeInterval(blockHours * 3600)
        )
    }

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> DateComponents {
        DateComponents(year: y, month: m, day: d, hour: h, minute: min)
    }

    static var typicalSleeper: Sleeper {
        Sleeper(
            chronotype: .intermediate,
            habitualBedtime: ClockTime(hour: 23),
            habitualWake: ClockTime(hour: 7),
            age: 30,
            usesMelatonin: true,
            usesCaffeine: true
        )
    }
}

extension CircadianPlan {
    func events(_ kind: PlanEvent.Kind) -> [PlanEvent] {
        events.filter { $0.kind == kind }
    }
    var lightEvents: [PlanEvent] {
        events.filter { $0.kind == .seekLight || $0.kind == .seekArtificialLight }
    }
    func day(_ index: Int) -> DayPlan? {
        days.first { $0.dayIndex == index }
    }
}
