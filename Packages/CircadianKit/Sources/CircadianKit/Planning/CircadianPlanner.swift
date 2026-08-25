import Foundation

/// Builds a jet-lag plan by *simulating* the pacemaker forward one day at a time.
///
/// The important structural difference from a naive planner: nothing here ramps the
/// schedule at a fixed "1 h per day". Each day the planner works out where the clock
/// currently is, aims a light window at the phase where the published PRC says light does
/// the most good, sizes that window from the dose–response law so it delivers no more
/// shift than is still needed, bends it around the user's real constraints and the real
/// sunrise, then asks the PRC how far the clock actually moved and steps forward. The
/// pace of adaptation is an *output*, not an assumption.
public struct CircadianPlanner: Sendable {

    public var estimator: PhaseShiftEstimator

    public init(estimator: PhaseShiftEstimator = PhaseShiftEstimator()) {
        self.estimator = estimator
    }

    /// Convenience initialiser honouring a PRC variant choice.
    public init(prcVariant: PRCVariant, melatoninMilligrams: Double = 0.5) {
        self.estimator = PhaseShiftEstimator(
            lightPRC: AdjustedPRC(base: .khalsa2003Light, variant: prcVariant),
            melatoninPRC: AdjustedPRC(
                base: melatoninMilligrams >= 1.5 ? .burgess2008Melatonin3mg : .burgess2010Melatonin05mg,
                variant: prcVariant
            )
        )
    }

    // MARK: - Pacing estimates

    /// A-priori adaptation rate in hours per day, used only to *decide* the strategy.
    ///
    /// Peak PRC amplitude scaled by an assumed compliance, plus the free-running drift,
    /// which helps delays and hinders advances. With the default 50% compliance this
    /// reproduces the clinical rules of thumb — roughly 1 h/day of advance and
    /// 1.5 h/day of delay — from the published curve rather than by assertion.
    public func dailyRate(for direction: ShiftDirection, sleeper: Sleeper, options: PlanOptions) -> Double {
        let drift = CircadianState.freeRunningDrift(for: sleeper)   // negative for τ > 24 h
        let peak = abs(estimator.lightPRC.base.shift(
            atPhase: estimator.optimalLightPhase(for: direction)
        )) * options.complianceFactor * sleeper.lightSensitivity
        switch direction {
        case .advance: return max(0.25, peak + drift)
        case .delay: return max(0.25, peak - drift)
        case .none: return 0
        }
    }

    // MARK: - Entry point

    public func makePlan(for request: TripPlanRequest) -> CircadianPlan {
        let sleeper = request.sleeper
        let options = request.options

        // The simulation and the strategy decision must assume the same compliance, or the
        // plan will pace itself differently from the way it justified itself.
        var estimator = self.estimator
        estimator.complianceFactor = options.complianceFactor

        let strategy = ShiftStrategy.decide(
            for: request,
            advanceRate: dailyRate(for: .advance, sleeper: sleeper, options: options),
            delayRate: dailyRate(for: .delay, sleeper: sleeper, options: options)
        )

        let timeline = DayTimeline(request: request)
        var state = initialState(for: request, firstDay: timeline.days.first)
        var cumulative: Double = 0
        var dayPlans: [DayPlan] = []
        var adaptationDay: Int?

        for slot in timeline.days {
            let goal = goalState(for: slot, request: request, strategy: strategy, sleeper: sleeper)
            var dayState = state.normalised(intoDayStartingAt: slot.localDayStart, timeZone: slot.place.timeZone)
            let normalisedGoal = goal.normalised(intoDayStartingAt: slot.localDayStart, timeZone: slot.place.timeZone)
            let remaining = dayState.shiftRequired(toReach: normalisedGoal)

            var builder = DayBuilder(
                slot: slot,
                state: dayState,
                remaining: remaining,
                request: request,
                strategy: strategy,
                estimator: estimator
            )
            let outcome = builder.build()

            cumulative += outcome.netShift
            state = dayState.applying(shiftHours: outcome.netShift)
            dayState = state

            let remainingAfter = remaining - outcome.netShift
            if adaptationDay == nil, abs(remainingAfter) < 0.5, strategy.kind != .noShiftNeeded {
                adaptationDay = slot.dayIndex
            }

            dayPlans.append(DayPlan(
                dayIndex: slot.dayIndex,
                localDayStart: slot.localDayStart,
                place: slot.place,
                cbtMinAtStart: builder.state.cbtMin,
                cbtMinAtEnd: state.cbtMin,
                achievedShiftHours: outcome.netShift,
                cumulativeShiftHours: cumulative,
                remainingShiftHours: remainingAfter,
                events: outcome.events.sorted { $0.interval.start < $1.interval.start },
                sunrise: slot.solarDay.sunrise,
                sunset: slot.solarDay.sunset,
                isPolarDay: slot.solarDay.isPolarDay,
                isPolarNight: slot.solarDay.isPolarNight,
                title: slot.title,
                notes: outcome.notes
            ))
        }

        let residual = dayPlans.last?.remainingShiftHours ?? 0
        return CircadianPlan(
            id: UUID(),
            request: request,
            strategy: strategy,
            days: dayPlans,
            achievedShiftHours: cumulative,
            dayAdaptationReached: adaptationDay,
            residualMisalignmentHours: residual,
            compromisedEventCount: dayPlans.flatMap(\.events).count(where: \.isCompromised)
        )
    }

    // MARK: - Phase bookkeeping

    /// The pacemaker phase the traveller starts from: their habitual temperature minimum,
    /// placed on the first day of the plan in home local time.
    private func initialState(for request: TripPlanRequest, firstDay: DaySlot?) -> CircadianState {
        let place = request.outbound.origin
        let anchor = firstDay?.localDayStart
            ?? place.calendar.startOfDay(for: request.outbound.departure)
        let cbt = anchor.addingTimeInterval(request.sleeper.estimatedCBTMin.hours * 3600)
        return CircadianState(cbtMin: cbt)
    }

    /// Where the plan is trying to get the clock to, on a given day.
    ///
    /// Expressed as a target *local clock time at the destination*, then resolved to an
    /// instant on the day in question. Recomputing the zone difference each day is what
    /// makes a daylight-saving transition partway through a trip come out right: the
    /// target simply moves with the local clock.
    private func goalState(
        for slot: DaySlot,
        request: TripPlanRequest,
        strategy: ShiftStrategy,
        sleeper: Sleeper
    ) -> CircadianState {
        let habitual = sleeper.estimatedCBTMin.hours

        // After the return flight departs, the goal is home time again.
        if slot.isAfterReturnDeparture {
            let origin = request.outbound.origin
            let dayStart = origin.calendar.startOfDay(for: slot.localDayStart.addingTimeInterval(12 * 3600))
            return CircadianState(cbtMin: dayStart.addingTimeInterval(habitual * 3600))
        }

        let origin = request.outbound.origin
        let destination = request.outbound.destination
        let reference = slot.localDayStart.addingTimeInterval(12 * 3600)
        let delta = CircadianHours.signedOffset(
            destination.utcOffsetHours(at: reference) - origin.utcOffsetHours(at: reference)
        )

        // Local clock at the destination that the target phase corresponds to.
        // Full shift  -> habitual (fully local).  Stay on home time -> habitual + delta.
        // Partial     -> somewhere in between.
        let goalClock = CircadianHours.wrap24(habitual + delta - strategy.targetShiftHours)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = destination.timeZone
        let destinationDayStart = calendar.startOfDay(for: reference)
        return CircadianState(cbtMin: destinationDayStart.addingTimeInterval(goalClock * 3600))
    }
}

// MARK: - Day timeline

/// One day of the plan, with the place whose clock and sun govern it.
struct DaySlot {
    var dayIndex: Int
    var localDayStart: Date
    var place: Place
    var solarDay: SolarDay
    var title: String
    /// The outbound flight, if it overlaps this day.
    var outboundFlight: Flight?
    /// The return flight, if it overlaps this day.
    var returnFlight: Flight?
    var isAfterReturnDeparture: Bool
    var isArrivalDay: Bool
}

/// Walks the itinerary and produces the ordered list of local days to plan.
///
/// Days are produced by stepping to the next local midnight *in whichever zone governs
/// the next day*, which is what keeps the sequence correct across both the flight's zone
/// change and any daylight-saving transition at either end.
struct DayTimeline {
    var days: [DaySlot]

    init(request: TripPlanRequest) {
        let outbound = request.outbound
        let origin = outbound.origin
        let destination = outbound.destination
        let options = request.options

        // Day 0 is the local day the outbound flight departs.
        let day0 = origin.calendar.startOfDay(for: outbound.departure)

        let lastIndex: Int
        if let homebound = request.homebound {
            let arrivalHomeDay = origin.calendar.startOfDay(for: homebound.arrival)
            let dayCount = origin.calendar.dateComponents([.day], from: day0, to: arrivalHomeDay).day ?? 0
            lastIndex = dayCount + options.postTripDays
        } else {
            let arrivalDay = destination.calendar.startOfDay(for: outbound.arrival)
            let dayCount = destination.calendar.dateComponents([.day], from: day0, to: arrivalDay).day ?? 0
            lastIndex = dayCount + options.maxDestinationDays
        }

        func place(forDayStartingAt start: Date) -> Place {
            // The zone that governs a day is the one you are in for most of it.
            let middle = start.addingTimeInterval(12 * 3600)
            if let homebound = request.homebound, middle >= homebound.arrival { return origin }
            if middle >= outbound.arrival { return destination }
            return origin
        }

        var slots: [DaySlot] = []
        let firstIndex = -max(0, options.preflightDays)

        // Anchor the walk at day 0 and step outwards, snapping to local midnight in the
        // governing zone each time.
        var starts: [Int: Date] = [0: day0]
        var cursor = day0
        for index in 1...max(1, lastIndex) where index <= lastIndex {
            // Jump to roughly next local noon, then snap to that zone's midnight.
            let nominal = cursor.addingTimeInterval(36 * 3600)
            let nextPlace = place(forDayStartingAt: nominal.addingTimeInterval(-12 * 3600))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = nextPlace.timeZone
            cursor = calendar.startOfDay(for: nominal)
            starts[index] = cursor
        }
        cursor = day0
        for index in stride(from: -1, through: firstIndex, by: -1) {
            let nominal = cursor.addingTimeInterval(-12 * 3600)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = origin.timeZone
            cursor = calendar.startOfDay(for: nominal)
            starts[index] = cursor
        }

        for index in firstIndex...lastIndex {
            guard let start = starts[index] else { continue }
            let governing = place(forDayStartingAt: start)
            let dayEnd = start.addingTimeInterval(24 * 3600)
            let dayInterval = TimeWindow(start: start, end: dayEnd)

            let outboundOverlap = dayInterval.intersects(outbound.interval) ? outbound : nil
            let returnOverlap = request.homebound.flatMap {
                dayInterval.intersects($0.interval) ? $0 : nil
            }

            slots.append(DaySlot(
                dayIndex: index,
                localDayStart: start,
                place: governing,
                solarDay: governing.solarDay(containing: start.addingTimeInterval(12 * 3600)),
                title: Self.title(for: index, dayInterval: dayInterval, request: request),
                outboundFlight: outboundOverlap,
                returnFlight: returnOverlap,
                isAfterReturnDeparture: request.homebound.map { start.addingTimeInterval(12 * 3600) >= $0.departure } ?? false,
                isArrivalDay: dayInterval.contains(outbound.arrival)
            ))
        }
        self.days = slots
    }

    private static func title(for index: Int, dayInterval: TimeWindow, request: TripPlanRequest) -> String {
        if dayInterval.contains(request.outbound.departure) { return "Departure day" }
        if dayInterval.contains(request.outbound.arrival) { return "Arrival day" }
        if let homebound = request.homebound {
            if dayInterval.contains(homebound.departure) { return "Flying home" }
            if dayInterval.contains(homebound.arrival) { return "Home again" }
        }
        if index < 0 {
            return index == -1 ? "The day before you fly" : "\(-index) days before you fly"
        }
        return "Day \(index)"
    }
}

extension CircadianState {
    /// Places CBTmin on the single occurrence that falls inside the given local day.
    func normalised(intoDayStartingAt start: Date, timeZone: TimeZone) -> CircadianState {
        var candidate = cbtMin
        while candidate < start { candidate = candidate.addingTimeInterval(86400) }
        while candidate >= start.addingTimeInterval(86400) { candidate = candidate.addingTimeInterval(-86400) }
        return CircadianState(cbtMin: candidate)
    }
}
