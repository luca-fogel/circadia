import Foundation

/// The four things a planner can decide to do about a trip.
public enum ShiftStrategyKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// The zone change is too small to be worth acting on.
    case noShiftNeeded
    /// Deliberately stay on home time. The "quick turnaround" case: the trip ends before
    /// adaptation could pay for itself, so shifting twice costs more than it buys.
    case stayOnHomeTime
    /// Shift part of the way and meet the destination in the middle.
    case partialShift
    /// Shift all the way onto destination time.
    case fullShift

    public var displayName: String {
        switch self {
        case .noShiftNeeded: "No shift needed"
        case .stayOnHomeTime: "Stay on home time"
        case .partialShift: "Partial shift"
        case .fullShift: "Full shift"
        }
    }
}

/// The decision about *whether* and *how far* to shift, made before any window is placed.
public struct ShiftStrategy: Hashable, Sendable, Codable {
    public var kind: ShiftStrategyKind
    /// Direction of the shift the plan will pursue.
    public var direction: ShiftDirection
    /// Signed target shift in hours: positive advances, negative delays.
    public var targetShiftHours: Double
    /// Signed clock difference between origin and destination.
    public var zoneDifferenceHours: Double
    /// Magnitude of shift a full adaptation would require in the chosen direction.
    public var fullShiftMagnitude: Double
    /// A-priori pacing estimate, hours per day.
    public var estimatedDailyRate: Double
    /// Days a full adaptation is expected to take at that rate.
    public var estimatedDaysToAdapt: Double
    public var stayHours: Double?
    /// Human-readable reason, shown in the UI so the advice is never unexplained.
    public var rationale: String
    /// True when the engine chose the direction opposite to the direction of travel —
    /// e.g. delaying 11 h for a 13 h eastward hop, because 11 h of delay is cheaper than
    /// 13 h of advance.
    public var isCounterIntuitiveDirection: Bool

    /// Decides the strategy for a request.
    ///
    /// Two independent judgements are made here:
    ///
    /// **Direction.** A `d`-hour eastward change can be met by advancing `d` hours *or* by
    /// delaying `24 − d` hours. Because delays come more easily than advances — the
    /// intrinsic period is longer than 24 h and the delay lobe of the PRC is larger — the
    /// cheaper option is not always the one that matches the direction of the flight. The
    /// engine compares *days of adaptation*, not hours, so for the classic 13–14 h
    /// eastward hops it correctly recommends delaying.
    ///
    /// **Whether to shift at all.** Adaptation only pays off if there is enough time at
    /// the destination to enjoy being adapted. Comparing the stay against the estimated
    /// adaptation time gives three regimes: leave before you would have adapted (stay on
    /// home time), barely enough time (meet in the middle), or plenty (shift fully).
    public static func decide(
        for request: TripPlanRequest,
        advanceRate: Double,
        delayRate: Double
    ) -> ShiftStrategy {
        let delta = request.outbound.zoneDifferenceHours

        // The two ways round the clock.
        let advanceMagnitude = CircadianHours.wrap24(delta)
        let delayMagnitude = 24 - advanceMagnitude

        let advanceDays = advanceMagnitude / max(advanceRate, 0.1)
        let delayDays = delayMagnitude / max(delayRate, 0.1)

        // Tiny zone changes: nothing to plan.
        if abs(delta) < 1.5 {
            return ShiftStrategy(
                kind: .noShiftNeeded,
                direction: .none,
                targetShiftHours: 0,
                zoneDifferenceHours: delta,
                fullShiftMagnitude: abs(delta),
                estimatedDailyRate: 0,
                estimatedDaysToAdapt: 0,
                stayHours: request.stayHours,
                rationale: abs(delta) < 0.25
                    ? "Your destination keeps the same clock time as home, so there is nothing to shift."
                    : String(format: "A %.1f h clock change is smaller than the day-to-day variation in your own body clock. Keep your usual schedule and you will be fine.", abs(delta)),
                isCounterIntuitiveDirection: false
            )
        }

        // Cheaper direction wins; ties go to delay, which is the more forgiving direction.
        let preferDelay = delayDays <= advanceDays
        let direction: ShiftDirection = preferDelay ? .delay : .advance
        let magnitude = preferDelay ? delayMagnitude : advanceMagnitude
        let rate = preferDelay ? delayRate : advanceRate
        let daysToAdapt = magnitude / max(rate, 0.1)

        // Did we pick the direction the aeroplane is not going?
        //
        // This has to test the *raw* offset difference, not the wrapped one: a 13 h
        // eastward hop wraps to a -11 h clock change, so comparing against the wrapped
        // value would never notice that the plan is delaying an eastward traveller.
        let travelSuggestsAdvance = request.outbound.rawZoneDifferenceHours > 0
        let counterIntuitive = travelSuggestsAdvance == preferDelay

        var directionNote = ""
        if counterIntuitive {
            directionNote = String(
                format: " You are flying %@, which would normally mean %@ing by %.0f h — but %@ing the other way round the clock by %.0f h reaches the same destination schedule in fewer days, so that is what this plan does.",
                travelSuggestsAdvance ? "east" : "west",
                travelSuggestsAdvance ? "advanc" : "delay",
                travelSuggestsAdvance ? advanceMagnitude : delayMagnitude,
                preferDelay ? "delay" : "advanc",
                magnitude
            )
        }

        func strategy(
            _ kind: ShiftStrategyKind,
            target: Double,
            rationale: String
        ) -> ShiftStrategy {
            ShiftStrategy(
                kind: kind,
                direction: kind == .stayOnHomeTime ? .none : direction,
                targetShiftHours: target,
                zoneDifferenceHours: delta,
                fullShiftMagnitude: magnitude,
                estimatedDailyRate: rate,
                estimatedDaysToAdapt: daysToAdapt,
                stayHours: request.stayHours,
                rationale: rationale + directionNote,
                isCounterIntuitiveDirection: counterIntuitive
            )
        }

        let fullTarget = magnitude * direction.sign

        // Honour an explicit override, but still report the reasoning.
        if let override = request.strategyOverride {
            switch override {
            case .noShiftNeeded:
                return strategy(.noShiftNeeded, target: 0, rationale: "You asked to skip shifting for this trip.")
            case .stayOnHomeTime:
                return strategy(.stayOnHomeTime, target: 0, rationale: "You asked to stay on home time for this trip.")
            case .partialShift:
                return strategy(.partialShift, target: fullTarget / 2, rationale: "You asked for a partial shift.")
            case .fullShift:
                return strategy(.fullShift, target: fullTarget, rationale: "You asked for a full shift onto destination time.")
            }
        }

        guard let stayHours = request.stayHours else {
            return strategy(.fullShift, target: fullTarget, rationale: String(
                format: "With no return date set, the plan assumes you are staying put, so it shifts you the whole %.0f h onto local time over about %.0f days.",
                magnitude, daysToAdapt.rounded()
            ))
        }

        let stayDays = stayHours / 24

        // Quick turnaround: you would leave while still mid-adaptation, and then have to
        // undo it. Staying on home time keeps one body clock instead of breaking two.
        if stayDays < daysToAdapt * 0.75 {
            return strategy(.stayOnHomeTime, target: 0, rationale: String(
                format: "You are at the destination for only %.1f days but a %.0f h shift takes about %.0f days. You would still be adapting when it is time to come home — and then have to shift back. Keeping your home schedule, even though the local clock disagrees, leaves you far better off.",
                stayDays, magnitude, daysToAdapt.rounded()
            ))
        }

        // Enough time to be worth moving, not enough to be worth moving all the way.
        if stayDays < daysToAdapt * 1.5 {
            let reachable = rate * stayDays / 2
            let partial = min(magnitude, max(1.0, reachable))
            if partial < 1.0 {
                return strategy(.stayOnHomeTime, target: 0, rationale: String(
                    format: "At %.1f days there is not enough time at the destination for a shift to repay the disruption.", stayDays
                ))
            }
            return strategy(.partialShift, target: partial * direction.sign, rationale: String(
                format: "A %.0f h shift would take about %.0f days and you have %.1f. The plan moves you %.1f h — most of the benefit, without leaving you stranded halfway when you fly home.",
                magnitude, daysToAdapt.rounded(), stayDays, partial
            ))
        }

        return strategy(.fullShift, target: fullTarget, rationale: String(
            format: "You have %.1f days at the destination and a %.0f h shift takes about %.0f, so there is time to adapt fully and enjoy it.",
            stayDays, magnitude, daysToAdapt.rounded()
        ))
    }
}
