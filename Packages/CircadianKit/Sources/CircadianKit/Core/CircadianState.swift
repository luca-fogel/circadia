import Foundation

/// The instantaneous phase of a person's circadian pacemaker, anchored to an absolute
/// instant rather than a wall-clock time.
///
/// Anchoring to `Date` is what makes DST and time-zone changes fall out for free: the
/// pacemaker does not care what the local clock says, only when the sun and the light
/// switch were. Local clock times are derived on demand via a `Calendar`.
public struct CircadianState: Hashable, Sendable {

    /// Instant of the core body temperature minimum for the current circadian cycle.
    public var cbtMin: Date

    public init(cbtMin: Date) {
        self.cbtMin = cbtMin
    }

    /// Dim-light melatonin onset, which precedes CBTmin by ~7 h
    /// (Burgess, Savic, Sletten et al. 2003; used as the melatonin PRC's reference).
    public static let dlmoToCBTMinHours: Double = 7

    public var dlmo: Date { cbtMin.addingTimeInterval(-Self.dlmoToCBTMinHours * 3600) }

    /// Circadian phase of `date`, in hours after CBTmin, wrapped to `[0, 24)`.
    ///
    /// This is the x-axis of the light PRC.
    public func phase(of date: Date, reference: PhaseReference = .cbtMin) -> Double {
        let anchor = reference == .cbtMin ? cbtMin : dlmo
        return CircadianHours.wrap24(date.timeIntervalSince(anchor) / 3600)
    }

    /// Applies a phase shift. Positive `hours` advances the clock, which moves every
    /// circadian landmark *earlier* in absolute time.
    public func applying(shiftHours hours: Double) -> CircadianState {
        CircadianState(cbtMin: cbtMin.addingTimeInterval(-hours * 3600))
    }

    /// Re-anchors CBTmin to the cycle nearest `date`, so phase arithmetic stays within
    /// one revolution as the plan walks forward day by day.
    public func normalised(near date: Date) -> CircadianState {
        let cycles = (date.timeIntervalSince(cbtMin) / 86400).rounded()
        return CircadianState(cbtMin: cbtMin.addingTimeInterval(cycles * 86400))
    }

    /// Signed distance from this phase to `target`, in hours, taking the short way round.
    /// Positive means `target` requires an advance.
    public func shiftRequired(toReach target: CircadianState) -> Double {
        -CircadianHours.signedOffset(target.cbtMin.timeIntervalSince(cbtMin) / 3600)
    }

    /// The sleep window this pacemaker phase implies for `sleeper`, holding the person's
    /// habitual phase angle between CBTmin and wake constant as the clock shifts.
    public func sleepWindow(for sleeper: Sleeper) -> TimeWindow {
        let wake = cbtMin.addingTimeInterval(sleeper.chronotype.cbtMinToWakeHours * 3600)
        let bed = wake.addingTimeInterval(-sleeper.sleepDurationHours * 3600)
        return TimeWindow(start: bed, end: wake)
    }

    /// Drift accumulated over one day with no light input, from the non-24 h intrinsic
    /// period. A τ longer than 24 h means the clock runs slow and delays each day —
    /// which is precisely why westward (delay) travel is easier to adapt to.
    ///
    /// Returned as a *shift*, so a τ of 24.15 h yields −0.15 h (a delay).
    public static func freeRunningDrift(for sleeper: Sleeper) -> Double {
        24 - sleeper.chronotype.intrinsicPeriodHours
    }
}
