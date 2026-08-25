import Foundation

/// Scales a phase-response-curve prediction for the *strength* of the light stimulus:
/// how bright it is, and how long it lasts.
///
/// Both relationships are strongly non-linear, and both are anchored to published
/// measurements rather than assumed linear.
public struct LightDoseResponse: Sendable, Hashable {

    /// Illuminance producing half of the maximal resetting response, in lux.
    ///
    /// Zeitzer, Dijk, Kronauer, Brown & Czeisler (2000), *J Physiol* 526:695, fitted a
    /// logistic illuminance–response curve for phase resetting with a half-maximal
    /// response near ~120 lux — i.e. ordinary indoor room light already achieves roughly
    /// half of what a bright light box does, and the response saturates well below
    /// daylight levels.
    public var halfSaturationLux: Double = 119

    /// Illuminance of the stimulus the reference PRC was measured with.
    public var referenceLux: Double = 9500

    /// Duration of the pulse the reference PRC was measured with, in hours.
    public var referenceDurationHours: Double = 6.7

    /// Exponent of the sub-linear duration–response power law.
    ///
    /// Derived from the two published white-light PRCs measured under the same protocol:
    /// a 1 h pulse yields a 2.20 h peak-to-trough amplitude (St Hilaire et al. 2012) and
    /// a 6.7 h pulse yields 5.02 h (Khalsa et al. 2003). Solving
    /// `(1/6.7)^p = 2.20/5.02` gives `p ≈ 0.434`, reproducing the papers' own observation
    /// that 15% of the exposure duration buys ~40% of the shift.
    public var durationExponent: Double = 0.4337

    /// Ceiling on the duration factor.
    ///
    /// The measured range is 1–6.7 h; extrapolating the power law to a 16 h day would
    /// predict a ~7 h single-day shift, which is not physiologically plausible for a
    /// Type 1 response. The factor is capped at the value a ~12.5 h exposure would give.
    public var maximumDurationFactor: Double = 1.30

    public init() {}

    /// Inverse of `illuminanceFactor(lux:)`.
    ///
    /// The planner averages the illuminance *factor* across a window whose brightness
    /// varies — part daylight, part light box, part asleep — because averaging lux and
    /// then saturating would overstate the dim portions. This converts that mean factor
    /// back into the single equivalent illuminance the estimator wants.
    public func equivalentLux(forFactor factor: Double) -> Double {
        let reference = referenceLux / (referenceLux + halfSaturationLux)
        let response = min(0.999, max(0, factor * reference))
        guard response > 0 else { return 0 }
        return halfSaturationLux * response / (1 - response)
    }

    /// Fraction of the reference response produced by light of the given illuminance.
    ///
    /// Returns 1.0 at `referenceLux`, ~0.5 of the *saturating* response at
    /// `halfSaturationLux`, and 0 in the dark.
    public func illuminanceFactor(lux: Double) -> Double {
        guard lux > 0 else { return 0 }
        let response = lux / (lux + halfSaturationLux)
        let reference = referenceLux / (referenceLux + halfSaturationLux)
        return response / reference
    }

    /// Fraction of the reference response produced by an exposure of the given duration.
    public func durationFactor(hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        let factor = pow(hours / referenceDurationHours, durationExponent)
        return min(factor, maximumDurationFactor)
    }

    /// Combined strength multiplier for a single exposure.
    public func factor(lux: Double, hours: Double) -> Double {
        illuminanceFactor(lux: lux) * durationFactor(hours: hours)
    }
}

/// Representative illuminances, for defaults and for explaining advice to the user.
public enum Illuminance {
    /// Direct summer sunlight.
    public static let directSunlight: Double = 100_000
    /// Outdoors under overcast sky — still far brighter than any interior.
    public static let overcastDaylight: Double = 10_000
    /// Sitting beside a bright window.
    public static let brightWindow: Double = 2_000
    /// A 10,000 lux therapy lamp at the recommended working distance.
    public static let lightBox: Double = 5_000
    /// Well-lit office or aircraft cabin with blinds up.
    public static let indoorBright: Double = 500
    /// Typical evening living-room lighting.
    public static let indoorDim: Double = 100
    /// Deliberate light avoidance: dim room, blue-blocking glasses, or an eye mask.
    public static let darkness: Double = 5
}
