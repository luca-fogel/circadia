import Foundation

/// One flight leg, stored as absolute instants so no time-zone ambiguity survives into
/// the engine.
public struct Flight: Hashable, Sendable, Codable {
    public var origin: Place
    public var destination: Place
    /// Wheels-up, as an absolute instant.
    public var departure: Date
    /// Wheels-down, as an absolute instant.
    public var arrival: Date

    public init(origin: Place, destination: Place, departure: Date, arrival: Date) {
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
    }

    /// Builds a leg from the local wall-clock times a traveller reads off a booking,
    /// resolving each against its own airport's zone at that date — so a flight that
    /// departs before a DST change and lands after it gets the right block time.
    public init?(
        origin: Place,
        destination: Place,
        localDeparture: DateComponents,
        localArrival: DateComponents
    ) {
        guard let dep = origin.calendar.date(from: localDeparture),
              let arr = destination.calendar.date(from: localArrival) else { return nil }
        self.init(origin: origin, destination: destination, departure: dep, arrival: arr)
    }

    public var blockTime: TimeInterval { arrival.timeIntervalSince(departure) }
    public var interval: TimeWindow { TimeWindow(start: departure, end: arrival) }

    /// Signed clock difference the traveller experiences, in `(-12, 12]` hours.
    ///
    /// Positive means the destination clock is ahead and the pacemaker must **advance**.
    /// Offsets are evaluated at the departure and arrival instants respectively, which is
    /// what makes DST correct: London→New York in late March differs from the same route
    /// in November.
    public var zoneDifferenceHours: Double {
        let originOffset = origin.utcOffsetHours(at: departure)
        let destinationOffset = destination.utcOffsetHours(at: arrival)
        return CircadianHours.signedOffset(destinationOffset - originOffset)
    }

    /// Raw, unwrapped offset difference — useful for explaining "you crossed 13 zones
    /// eastward but we will shift you 11 h westward".
    public var rawZoneDifferenceHours: Double {
        destination.utcOffsetHours(at: arrival) - origin.utcOffsetHours(at: departure)
    }
}

/// Knobs on plan generation. Defaults are the recommended settings.
public struct PlanOptions: Hashable, Sendable, Codable {
    /// How many days before departure the plan may start preparing.
    public var preflightDays: Int = 3
    /// How many days after the final arrival home the plan runs for.
    public var postTripDays: Int = 3
    /// Cap on days planned at the destination when there is no return leg.
    public var maxDestinationDays: Int = 7
    /// Melatonin dose the user takes, which changes the optimal timing.
    public var melatoninMilligrams: Double = 0.5
    /// Whether a light box / bright indoor lighting may be prescribed when the ideal
    /// window falls outside daylight hours.
    public var allowArtificialBrightLight: Bool = true
    /// Fraction of the PRC's theoretical daily maximum a real traveller is assumed to
    /// achieve, used for the a-priori pacing estimate. Real-world compliance, weather and
    /// competing light exposure all push the achieved shift below the laboratory maximum.
    public var complianceFactor: Double = 0.5
    /// Shortest light window worth prescribing, in hours.
    public var minimumLightWindowHours: Double = 0.75
    /// Longest light window worth prescribing, in hours.
    public var maximumLightWindowHours: Double = 6.7

    public init() {}
}

/// Everything needed to produce a plan.
public struct TripPlanRequest: Hashable, Sendable, Codable {
    public var outbound: Flight
    /// Return leg, if the traveller has one. Its presence is what lets the engine reason
    /// about whether shifting is worth it at all.
    public var homebound: Flight?
    public var sleeper: Sleeper
    public var constraints: [PracticalityConstraint]
    public var options: PlanOptions
    /// Forces a strategy instead of letting the engine decide. Surfaced in the UI as an
    /// override so a user can insist on shifting for a two-day trip.
    public var strategyOverride: ShiftStrategyKind?

    public init(
        outbound: Flight,
        homebound: Flight? = nil,
        sleeper: Sleeper = Sleeper(),
        constraints: [PracticalityConstraint] = [],
        options: PlanOptions = PlanOptions(),
        strategyOverride: ShiftStrategyKind? = nil
    ) {
        self.outbound = outbound
        self.homebound = homebound
        self.sleeper = sleeper
        self.constraints = constraints
        self.options = options
        self.strategyOverride = strategyOverride
    }

    /// Hours spent at the destination between arrival and the return departure.
    public var stayHours: Double? {
        guard let homebound else { return nil }
        return homebound.departure.timeIntervalSince(outbound.arrival) / 3600
    }
}
