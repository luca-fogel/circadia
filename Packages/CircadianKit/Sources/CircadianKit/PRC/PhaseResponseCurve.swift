import Foundation

/// A phase-response curve: how much a stimulus shifts the circadian pacemaker as a
/// function of *when* it is applied.
///
/// Sign convention throughout CircadianKit: **positive = phase advance** (the clock
/// moves earlier, what eastward travel needs), **negative = phase delay**.
public protocol PhaseResponseCurve: Sendable {
    /// Predicted shift in hours for a reference-strength stimulus whose centre falls
    /// at `phase` hours after the reference marker.
    ///
    /// `phase` is unwrapped by the implementation, so callers may pass any real value.
    func shift(atPhase phase: Double) -> Double

    /// The circadian marker `phase` is measured from.
    var reference: PhaseReference { get }

    /// Peak-to-trough amplitude of the curve, in hours.
    var amplitude: Double { get }
}

/// The circadian landmark a PRC's phase axis is anchored to.
public enum PhaseReference: String, Sendable, Codable {
    /// Core body temperature minimum. The light PRC is conventionally plotted against this.
    case cbtMin
    /// Dim-light melatonin onset, roughly 7 h before CBTmin. Melatonin PRCs use this.
    case dlmo
}

// MARK: - Dual harmonic sinusoid

/// A PRC of the functional form used by the Harvard/BWH group to fit their measured
/// curves: a dual-harmonic sinusoidal regression.
///
///     f(p) = a·sin(θ) + b·cos(θ) + c·sin(2θ) + d·cos(2θ),   θ = 2πp/24
///
/// The four coefficients are not published alongside the papers, so they are recovered
/// here by solving the linear system that forces the curve through the *published
/// landmarks*: the reported maximum advance and maximum delay, each constrained to be a
/// stationary point. That reproduces the published extrema exactly and lets the shape in
/// between follow the paper's own functional form rather than an invented one.
public struct DualHarmonicPRC: PhaseResponseCurve {

    /// The published extrema a curve is fitted through.
    public struct Landmarks: Hashable, Sendable {
        /// Largest phase advance, in hours (positive).
        public var maxAdvance: Double
        /// Phase, in hours after the reference marker, at which `maxAdvance` occurs.
        public var maxAdvancePhase: Double
        /// Largest phase delay, in hours (positive magnitude).
        public var maxDelay: Double
        /// Phase, in hours after the reference marker, at which `maxDelay` occurs.
        public var maxDelayPhase: Double

        public init(maxAdvance: Double, maxAdvancePhase: Double, maxDelay: Double, maxDelayPhase: Double) {
            self.maxAdvance = maxAdvance
            self.maxAdvancePhase = maxAdvancePhase
            self.maxDelay = maxDelay
            self.maxDelayPhase = maxDelayPhase
        }
    }

    public let reference: PhaseReference
    public let landmarks: Landmarks
    /// Fitted coefficients `(a, b, c, d)`.
    public let coefficients: (a: Double, b: Double, c: Double, d: Double)
    /// Documentation of where `landmarks` came from.
    public let citation: String

    public init(landmarks: Landmarks, reference: PhaseReference, citation: String) {
        self.landmarks = landmarks
        self.reference = reference
        self.citation = citation
        self.coefficients = Self.fit(landmarks)
    }

    /// Builds and solves the 4x4 system:
    ///   f(advancePhase)  = +maxAdvance     f'(advancePhase) = 0
    ///   f(delayPhase)    = -maxDelay       f'(delayPhase)   = 0
    private static func fit(_ l: Landmarks) -> (a: Double, b: Double, c: Double, d: Double) {
        func basis(_ phase: Double) -> [Double] {
            let t = 2 * Double.pi * phase / 24
            return [sin(t), cos(t), sin(2 * t), cos(2 * t)]
        }
        // d/dphase of the basis, dropping the common 2π/24 factor (it cancels in `= 0`).
        func basisDerivative(_ phase: Double) -> [Double] {
            let t = 2 * Double.pi * phase / 24
            return [cos(t), -sin(t), 2 * cos(2 * t), -2 * sin(2 * t)]
        }

        let matrix = [
            basis(l.maxAdvancePhase),
            basisDerivative(l.maxAdvancePhase),
            basis(l.maxDelayPhase),
            basisDerivative(l.maxDelayPhase)
        ]
        let rhs = [l.maxAdvance, 0, -l.maxDelay, 0]

        guard let s = LinearSolver.solve(matrix: matrix, vector: rhs) else {
            // Degenerate landmarks (e.g. both extrema at the same phase). Fall back to a
            // single harmonic through the advance landmark so the engine stays usable.
            let amp = (l.maxAdvance + l.maxDelay) / 2
            return (amp, 0, 0, 0)
        }
        return (s[0], s[1], s[2], s[3])
    }

    public func shift(atPhase phase: Double) -> Double {
        let t = 2 * Double.pi * CircadianHours.wrap24(phase) / 24
        return coefficients.a * sin(t) + coefficients.b * cos(t)
            + coefficients.c * sin(2 * t) + coefficients.d * cos(2 * t)
    }

    public var amplitude: Double { landmarks.maxAdvance + landmarks.maxDelay }

    /// Slope of the curve at `phase`, in hours of shift per hour of timing, useful for
    /// deciding how much a window may be nudged before it loses efficacy.
    public func slope(atPhase phase: Double) -> Double {
        let k = 2 * Double.pi / 24
        let t = k * CircadianHours.wrap24(phase)
        return k * (coefficients.a * cos(t) - coefficients.b * sin(t)
            + 2 * coefficients.c * cos(2 * t) - 2 * coefficients.d * sin(2 * t))
    }

    /// Phase, in `[0, 24)`, at which the curve attains its maximum advance, found by
    /// dense sampling then refinement. Used by tests and by the window optimiser.
    public func phaseOfPeak(advance: Bool) -> Double {
        var best = 0.0
        var bestValue = advance ? -.infinity : Double.infinity
        for i in 0..<2400 {
            let p = Double(i) / 100
            let v = shift(atPhase: p)
            if advance ? (v > bestValue) : (v < bestValue) {
                bestValue = v
                best = p
            }
        }
        return best
    }

    /// Zero crossings of the curve in `[0, 24)`, paired with the sign of the curve just
    /// after each one. The crossing where the sign turns positive is the physiological
    /// "advance/delay boundary" — for light it should land on the reference marker.
    public func zeroCrossings() -> [(phase: Double, becomesAdvance: Bool)] {
        var result: [(Double, Bool)] = []
        let step = 0.01
        var previous = shift(atPhase: 0)
        var p = step
        while p < 24 {
            let current = shift(atPhase: p)
            if previous == 0 || (previous < 0) != (current < 0) {
                // Linear refinement between the bracketing samples.
                let crossing = p - step + step * abs(previous) / max(abs(previous) + abs(current), 1e-12)
                result.append((CircadianHours.wrap24(crossing), current > 0))
            }
            previous = current
            p += step
        }
        return result.map { (phase: $0.0, becomesAdvance: $0.1) }
    }
}

// MARK: - Published curves

public extension DualHarmonicPRC {

    /// Light PRC to a single 6.7 h pulse of bright white light (~9500 lux), plotted
    /// against the phase of the *centre* of the exposure relative to CBTmin.
    ///
    /// Khalsa, Jewett, Cajochen & Czeisler (2003), *J Physiol* 549:945–952:
    /// maximum advance +2.32 h at circadian phase 4.05 h, maximum delay −2.70 h at
    /// circadian phase 19.38 h, fitted peak-to-trough amplitude 5.02 h.
    ///
    /// The paper explicitly reports **no evidence of a significant dead zone**: advances
    /// taper gradually across the subjective day and give way to delays roughly 12 h
    /// after CBTmin. This curve therefore has a low-sensitivity subjective day rather
    /// than a hard dead zone. See `PRCVariant.deadZone` if you want one anyway.
    static let khalsa2003Light = DualHarmonicPRC(
        landmarks: Landmarks(
            maxAdvance: 2.32,
            maxAdvancePhase: 4.05,
            maxDelay: 2.70,
            maxDelayPhase: 19.38
        ),
        reference: .cbtMin,
        citation: "Khalsa et al. (2003) J Physiol 549:945 — 6.7 h, ~9500 lux white light"
    )

    /// Light PRC to a single 1 h pulse of bright white light (~8000 lux).
    ///
    /// St Hilaire, Gooley, Khalsa, Kronauer, Czeisler & Lockley (2012),
    /// *J Physiol* 590:3035–3045: a Type 1 PRC with fitted peak-to-trough amplitude
    /// 2.20 h — about 40% of the 6.7 h curve's amplitude from only 15% of the exposure
    /// duration, which is where `LightDoseResponse`'s sub-linear duration law comes from.
    ///
    /// The published paper does not tabulate the extrema separately, so the Khalsa
    /// extremum *phases* are reused and the amplitudes scaled to 2.20 h peak-to-trough,
    /// preserving Khalsa's advance:delay ratio. Flagged in DEVIATIONS.md.
    static let stHilaire2012Light = DualHarmonicPRC(
        landmarks: Landmarks(
            maxAdvance: 2.20 * (2.32 / 5.02),
            maxAdvancePhase: 4.05,
            maxDelay: 2.20 * (2.70 / 5.02),
            maxDelayPhase: 19.38
        ),
        reference: .cbtMin,
        citation: "St Hilaire et al. (2012) J Physiol 590:3035 — 1 h, ~8000 lux white light"
    )

    /// PRC to 3.0 mg oral melatonin given on three consecutive days, plotted against
    /// time relative to DLMO.
    ///
    /// Burgess, Revell & Eastman (2008), *J Physiol* 586:639–647: maximum advance 1.8 h
    /// and maximum delay 1.3 h across the three-pulse protocol, fitted with a dual
    /// harmonic sinusoidal regression.
    ///
    /// Amplitudes are divided by three here to express a **per-dose** shift, since the
    /// planner administers one dose per day and sums across days itself.
    ///
    /// Extremum timings follow Burgess, Revell, Molina & Eastman (2010),
    /// *J Clin Endocrinol Metab* 95:3325: advances are maximal for afternoon dosing a few
    /// hours before DLMO — earlier for 3.0 mg than for 0.5 mg — with delays maximal after
    /// habitual wake. These timings are read off the published description rather than a
    /// coefficient table; see DEVIATIONS.md.
    static let burgess2008Melatonin3mg = DualHarmonicPRC(
        landmarks: Landmarks(
            maxAdvance: 1.8 / 3,
            maxAdvancePhase: 24 - 5,   // 5 h before DLMO
            maxDelay: 1.3 / 3,
            maxDelayPhase: 11          // 11 h after DLMO, i.e. after habitual wake
        ),
        reference: .dlmo,
        citation: "Burgess et al. (2008) J Physiol 586:639 — 3.0 mg oral melatonin, per-dose"
    )

    /// PRC to 0.5 mg oral melatonin. Same peak magnitudes as 3.0 mg when each is given at
    /// its own optimum, but the optimum sits later — 2–4 h before DLMO
    /// (Burgess et al. 2010). The lower dose is the planner's default because it produces
    /// equivalent shifts with less next-day grogginess.
    static let burgess2010Melatonin05mg = DualHarmonicPRC(
        landmarks: Landmarks(
            maxAdvance: 1.8 / 3,
            maxAdvancePhase: 24 - 3,   // 3 h before DLMO
            maxDelay: 1.3 / 3,
            maxDelayPhase: 13
        ),
        reference: .dlmo,
        citation: "Burgess et al. (2010) JCEM 95:3325 — 0.5 mg oral melatonin, per-dose"
    )
}

/// Optional post-processing applied on top of a fitted curve.
public enum PRCVariant: Sendable {
    /// Use the fitted curve as published. **Default**, and what the evidence supports.
    case asPublished
    /// Force a hard dead zone across the mid-subjective day by attenuating the curve
    /// between `from` and `to` hours after the reference marker.
    ///
    /// Khalsa et al. (2003) found no significant dead zone in humans, so this is off by
    /// default. It exists because limit-cycle models of the pacemaker (Kronauer/Jewett)
    /// and most non-human PRCs do include one, and because comparing the two is
    /// instructive.
    case deadZone(from: Double, to: Double, attenuation: Double)
}

/// A PRC wrapped with a variant transformation.
public struct AdjustedPRC: PhaseResponseCurve {
    public let base: DualHarmonicPRC
    public let variant: PRCVariant

    public init(base: DualHarmonicPRC, variant: PRCVariant = .asPublished) {
        self.base = base
        self.variant = variant
    }

    public var reference: PhaseReference { base.reference }
    public var amplitude: Double { base.amplitude }

    public func shift(atPhase phase: Double) -> Double {
        let raw = base.shift(atPhase: phase)
        switch variant {
        case .asPublished:
            return raw
        case let .deadZone(from, to, attenuation):
            let p = CircadianHours.wrap24(phase)
            let inside = from <= to ? (p >= from && p <= to) : (p >= from || p <= to)
            return inside ? raw * attenuation : raw
        }
    }
}
