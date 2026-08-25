import Testing
import Foundation
@testable import CircadianKit

@Suite("Phase response curve")
struct PhaseResponseCurveTests {

    let light = DualHarmonicPRC.khalsa2003Light

    @Test("Fit reproduces the published Khalsa 2003 extrema")
    func reproducesPublishedExtrema() {
        #expect(abs(light.shift(atPhase: 4.05) - 2.32) < 0.001)
        #expect(abs(light.shift(atPhase: 19.38) + 2.70) < 0.001)
        #expect(abs(light.amplitude - 5.02) < 0.001)
    }

    @Test("Published extrema are genuine stationary points, so nothing overshoots them")
    func extremaAreStationary() {
        #expect(abs(light.slope(atPhase: 4.05)) < 1e-9)
        #expect(abs(light.slope(atPhase: 19.38)) < 1e-9)

        // The global extremes of the fitted curve must be the published ones.
        let peak = light.phaseOfPeak(advance: true)
        let trough = light.phaseOfPeak(advance: false)
        #expect(abs(peak - 4.05) < 0.02)
        #expect(abs(trough - 19.38) < 0.02)
        #expect(light.shift(atPhase: peak) <= 2.321)
        #expect(light.shift(atPhase: trough) >= -2.701)
    }

    @Test("Light before CBTmin delays and light after CBTmin advances")
    func crossoverSitsAtTheTemperatureMinimum() {
        // Khalsa: "a relatively rapid transition from phase delays to phase advances
        // occurs near circadian phase 0 h".
        for hoursBefore in [1.0, 2.0, 3.0, 4.0] {
            #expect(light.shift(atPhase: 24 - hoursBefore) < 0, "light \(hoursBefore) h before CBTmin should delay")
        }
        for hoursAfter in [1.0, 2.0, 3.0, 4.0] {
            #expect(light.shift(atPhase: hoursAfter) > 0, "light \(hoursAfter) h after CBTmin should advance")
        }

        let crossings = light.zeroCrossings()
        let toAdvance = crossings.filter(\.becomesAdvance)
        #expect(toAdvance.count == 1)
        // Within an hour of the temperature minimum.
        let phase = CircadianHours.signedOffset(toAdvance[0].phase)
        #expect(abs(phase) < 1.0, "delay-to-advance crossing at \(phase) h should sit near CBTmin")
    }

    @Test("Advances give way to delays roughly 12 h after CBTmin")
    func secondCrossingIsInTheSubjectiveDay() {
        let toDelay = light.zeroCrossings().filter { !$0.becomesAdvance }
        #expect(toDelay.count == 1)
        #expect(abs(toDelay[0].phase - 12) < 2.5, "got \(toDelay[0].phase)")
    }

    @Test("Advances taper gradually across the subjective day, with no dead zone")
    func noHardDeadZoneByDefault() {
        // Khalsa: "there is no evidence of a significant dead zone in this study...
        // phase advances diminish gradually during the course of the early subjective
        // day". So the testable claims are (a) nowhere is the response flat at zero, and
        // (b) the decline from the advance peak is monotone rather than a cliff.
        var previous = light.shift(atPhase: 4.05)
        for phase in stride(from: 4.5, through: 11.5, by: 0.5) {
            let value = light.shift(atPhase: phase)
            #expect(value < previous, "advance should keep shrinking at phase \(phase)")
            #expect(value != 0, "no dead zone: phase \(phase) should still respond")
            previous = value
        }
        // By late subjective day the response is a small fraction of the peak.
        #expect(abs(light.shift(atPhase: 11.5)) < abs(light.shift(atPhase: 4.05)) / 5)
    }

    @Test("The optional dead-zone variant attenuates the subjective day")
    func deadZoneVariantIsAvailableButOptIn() {
        let plain = AdjustedPRC(base: light, variant: .asPublished)
        let dead = AdjustedPRC(base: light, variant: .deadZone(from: 7, to: 14, attenuation: 0))
        #expect(dead.shift(atPhase: 10) == 0)
        #expect(plain.shift(atPhase: 10) != 0)
        // Outside the zone the two agree exactly.
        #expect(dead.shift(atPhase: 4.05) == plain.shift(atPhase: 4.05))
    }

    @Test("The 1 h curve is weaker than the 6.7 h curve at the same phase")
    func shorterPulseIsWeaker() {
        let short = DualHarmonicPRC.stHilaire2012Light
        #expect(abs(short.amplitude - 2.20) < 0.001)
        #expect(abs(short.shift(atPhase: 4.05)) < abs(light.shift(atPhase: 4.05)))
    }

    @Test("The melatonin curve advances for afternoon dosing and delays after waking")
    func melatoninCurveHasTheRightPolarity() {
        let melatonin = DualHarmonicPRC.burgess2010Melatonin05mg
        #expect(melatonin.reference == .dlmo)
        // 3 h before DLMO -> advance.
        #expect(melatonin.shift(atPhase: 21) > 0)
        // Well after DLMO, in the morning -> delay.
        #expect(melatonin.shift(atPhase: 13) < 0)
        // Per-dose amplitude is modest next to light.
        #expect(melatonin.amplitude < light.amplitude / 4)
    }

    @Test("A degenerate landmark pair falls back instead of trapping or crashing")
    func degenerateFitDoesNotCrash() {
        let curve = DualHarmonicPRC(
            landmarks: .init(maxAdvance: 1, maxAdvancePhase: 5, maxDelay: 1, maxDelayPhase: 5),
            reference: .cbtMin,
            citation: "degenerate"
        )
        #expect(curve.shift(atPhase: 3).isFinite)
    }
}

@Suite("Light dose response")
struct LightDoseResponseTests {

    let dose = LightDoseResponse()

    @Test("Duration factor is anchored to both published pulse durations")
    func durationLawMatchesBothPapers() {
        // 6.7 h is the reference, so exactly 1.0.
        #expect(abs(dose.durationFactor(hours: 6.7) - 1.0) < 1e-9)
        // A 1 h pulse achieved ~40% of the 6.7 h amplitude (2.20 / 5.02 = 0.438).
        #expect(abs(dose.durationFactor(hours: 1) - 2.20 / 5.02) < 0.005)
    }

    @Test("Duration response is sub-linear and capped")
    func durationIsSubLinearAndCapped() {
        // Doubling the duration must buy less than double the shift.
        let two = dose.durationFactor(hours: 2)
        let four = dose.durationFactor(hours: 4)
        #expect(four < two * 2)
        #expect(dose.durationFactor(hours: 24) == dose.maximumDurationFactor)
        #expect(dose.durationFactor(hours: 0) == 0)
    }

    @Test("Illuminance saturates well below daylight")
    func illuminanceSaturates() {
        #expect(abs(dose.illuminanceFactor(lux: 9500) - 1.0) < 1e-9)
        #expect(dose.illuminanceFactor(lux: 0) == 0)
        // Zeitzer et al.: ordinary room light already buys about half the saturating
        // response, so the half-saturation point must be near indoor levels.
        let atHalfSat = dose.illuminanceFactor(lux: dose.halfSaturationLux)
        #expect(atHalfSat > 0.45 && atHalfSat < 0.55)
        // Going from daylight to direct sun buys almost nothing.
        #expect(dose.illuminanceFactor(lux: 100_000) - dose.illuminanceFactor(lux: 10_000) < 0.05)
        // Monotone.
        var previous = 0.0
        for lux in stride(from: 1.0, through: 50_000, by: 250) {
            let f = dose.illuminanceFactor(lux: lux)
            #expect(f >= previous)
            previous = f
        }
    }

    @Test("Equivalent-lux inversion round-trips")
    func inversionRoundTrips() {
        for lux in [10.0, 100, 500, 2_000, 9_500] {
            let factor = dose.illuminanceFactor(lux: lux)
            let back = dose.equivalentLux(forFactor: factor)
            #expect(abs(back - lux) / lux < 0.01, "\(lux) -> \(factor) -> \(back)")
        }
    }
}
