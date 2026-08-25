import Foundation

/// A single stimulus the plan prescribes, ready to be scored by the PRC.
public struct Stimulus: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Light exposure at the given illuminance.
        case light(lux: Double)
        /// An oral melatonin dose, taken at `interval.start`.
        case melatonin(milligrams: Double)
    }

    public var kind: Kind
    public var interval: TimeWindow

    public init(kind: Kind, interval: TimeWindow) {
        self.kind = kind
        self.interval = interval
    }
}

/// Predicts how far a set of stimuli moves the pacemaker over a single circadian cycle.
///
/// The published PRCs describe *one discrete pulse per cycle*, so each stimulus is scored
/// as a pulse: the PRC is evaluated at the circadian phase of the pulse's **centre**
/// (Khalsa et al.'s own x-axis convention) and scaled for the pulse's brightness and
/// duration. Nothing is integrated over the window, because the measured curve is not a
/// sensitivity density and treating it as one would double-count duration — which
/// `LightDoseResponse.durationFactor` already handles, sub-linearly.
public struct PhaseShiftEstimator: Sendable {

    public var lightPRC: AdjustedPRC
    public var melatoninPRC: AdjustedPRC
    public var doseResponse: LightDoseResponse

    /// Ceiling on the net shift attributable to one cycle's stimuli.
    ///
    /// Multiple exposures in a day do not sum linearly — the pacemaker's response
    /// saturates. Contributions are summed and then squashed through a soft limiter that
    /// is linear for small totals and asymptotes at this value. Set from Khalsa's
    /// single-pulse maxima, which no realistic day should be able to beat outright.
    public var maximumDailyShift: Double = 3.0

    /// Fraction of the laboratory response a real traveller is assumed to achieve.
    ///
    /// The published PRCs come from inpatient protocols: constant routine, controlled dim
    /// background light, a compliant subject sitting in front of a light box for 6.7 h.
    /// A traveller gets cloud, a phone screen, a taxi and a meeting. Every predicted shift
    /// is scaled by this so the numbers shown to the user are what they can expect rather
    /// than a laboratory ceiling — and so the plan's own pacing agrees with the pacing the
    /// strategy layer used to choose the strategy in the first place.
    public var complianceFactor: Double = 0.5

    public init(
        lightPRC: AdjustedPRC = AdjustedPRC(base: .khalsa2003Light),
        melatoninPRC: AdjustedPRC = AdjustedPRC(base: .burgess2010Melatonin05mg),
        doseResponse: LightDoseResponse = LightDoseResponse()
    ) {
        self.lightPRC = lightPRC
        self.melatoninPRC = melatoninPRC
        self.doseResponse = doseResponse
    }

    /// Predicted shift in hours from one stimulus, positive for an advance.
    public func shift(for stimulus: Stimulus, state: CircadianState, sleeper: Sleeper) -> Double {
        switch stimulus.kind {
        case let .light(lux):
            let hours = stimulus.interval.durationHours
            guard hours > 0, lux > 0 else { return 0 }
            let phase = state.phase(of: stimulus.interval.midpoint, reference: lightPRC.reference)
            let raw = lightPRC.shift(atPhase: phase)
            return raw * doseResponse.factor(lux: lux, hours: hours)
                * sleeper.lightSensitivity * complianceFactor

        case let .melatonin(mg):
            // The dose changes *when* to take it, not how much it can do; the two
            // published doses reach comparable maxima at their own optimal times.
            let curve = mg >= 1.5
                ? AdjustedPRC(base: .burgess2008Melatonin3mg, variant: melatoninPRC.variant)
                : melatoninPRC
            let phase = state.phase(of: stimulus.interval.start, reference: curve.reference)
            return curve.shift(atPhase: phase) * sleeper.lightSensitivity * complianceFactor
        }
    }

    /// Net predicted shift over one cycle, including free-running drift.
    public func netShift(
        stimuli: [Stimulus],
        state: CircadianState,
        sleeper: Sleeper,
        includeDrift: Bool = true
    ) -> Double {
        let sum = stimuli.reduce(0) { $0 + shift(for: $1, state: state, sleeper: sleeper) }
        let limited = softLimit(sum)
        return limited + (includeDrift ? CircadianState.freeRunningDrift(for: sleeper) : 0)
    }

    /// Odd, monotone saturating limiter: `f(x) ≈ x` for small `|x|`, `|f| < maximumDailyShift`.
    func softLimit(_ x: Double) -> Double {
        let m = maximumDailyShift
        guard m > 0 else { return 0 }
        return m * tanh(x / m)
    }

    /// The phase, relative to CBTmin, at which light most strongly produces a shift in
    /// `direction`. Used to aim the seek-light window.
    public func optimalLightPhase(for direction: ShiftDirection) -> Double {
        switch direction {
        case .advance: lightPRC.base.phaseOfPeak(advance: true)
        case .delay: lightPRC.base.phaseOfPeak(advance: false)
        case .none: 0
        }
    }

    /// The phase at which light most strongly produces a shift in the *wrong* direction,
    /// which is what the avoid-light window is there to cover.
    public func worstLightPhase(for direction: ShiftDirection) -> Double {
        optimalLightPhase(for: direction.opposite)
    }
}
