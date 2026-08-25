import Testing
import Foundation
@testable import CircadianKit

@Suite("Shift strategy")
struct ShiftStrategyTests {

    let planner = CircadianPlanner()

    func decide(_ request: TripPlanRequest) -> ShiftStrategy {
        ShiftStrategy.decide(
            for: request,
            advanceRate: planner.dailyRate(for: .advance, sleeper: request.sleeper, options: request.options),
            delayRate: planner.dailyRate(for: .delay, sleeper: request.sleeper, options: request.options)
        )
    }

    @Test("Published PRC amplitudes at 50% compliance reproduce the clinical rules of thumb")
    func pacingMatchesClinicalGuidance() {
        let sleeper = Fixture.typicalSleeper
        let advance = planner.dailyRate(for: .advance, sleeper: sleeper, options: PlanOptions())
        let delay = planner.dailyRate(for: .delay, sleeper: sleeper, options: PlanOptions())
        // The textbook figures are ~1 h/day of advance and ~1.5 h/day of delay. Those fall
        // out of Khalsa's peaks at 50% compliance plus the free-running drift, rather than
        // being hardcoded.
        #expect(abs(advance - 1.0) < 0.15, "advance rate \(advance)")
        #expect(abs(delay - 1.5) < 0.15, "delay rate \(delay)")
        #expect(delay > advance, "delays must be easier than advances")
    }

    @Test("Eastward travel advances the clock")
    func eastwardAdvances() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.cdg, departLocal: Fixture.local(2026, 9, 10, 19), blockHours: 7),
            sleeper: Fixture.typicalSleeper
        )
        let strategy = decide(trip)
        #expect(strategy.direction == .advance)
        #expect(strategy.kind == .fullShift)
        #expect(strategy.targetShiftHours > 5)
        #expect(!strategy.isCounterIntuitiveDirection)
    }

    @Test("Westward travel delays the clock")
    func westwardDelays() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11),
            sleeper: Fixture.typicalSleeper
        )
        let strategy = decide(trip)
        #expect(strategy.direction == .delay)
        #expect(strategy.targetShiftHours < -7)
        #expect(!strategy.isCounterIntuitiveDirection)
    }

    @Test("A very long eastward hop is planned as a delay, because that is cheaper")
    func longEastwardTripDelaysInstead() {
        // New York to Tokyo is 13 h of clock change eastward, which wraps to an 11 h
        // delay. Advancing 13 h at ~1 h/day costs thirteen days; delaying 11 h at
        // ~1.5 h/day costs seven. The engine should take the delay.
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.nrt, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 14),
            sleeper: Fixture.typicalSleeper
        )
        let strategy = decide(trip)
        #expect(trip.outbound.rawZoneDifferenceHours == 13)
        #expect(strategy.direction == .delay)
        #expect(abs(strategy.fullShiftMagnitude - 11) < 0.01)
        #expect(strategy.isCounterIntuitiveDirection, "should flag that it is going against the flight direction")
        #expect(strategy.rationale.contains("east"))
    }

    @Test("A one-hour zone change needs no plan at all")
    func shortHopNeedsNothing() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.cdg, departLocal: Fixture.local(2026, 9, 10, 9), blockHours: 1.25),
            sleeper: Fixture.typicalSleeper
        )
        let strategy = decide(trip)
        #expect(strategy.kind == .noShiftNeeded)
        #expect(strategy.direction == .none)
        #expect(strategy.targetShiftHours == 0)
    }

    @Test("A same-zone flight needs no plan even though it is long")
    func sameZoneLongHaulNeedsNothing() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.dub, departLocal: Fixture.local(2026, 9, 10, 9), blockHours: 1.25),
            sleeper: Fixture.typicalSleeper
        )
        #expect(decide(trip).kind == .noShiftNeeded)
    }

    @Test("Quick turnaround: a two-night trip across eight zones stays on home time")
    func quickTurnaroundStaysOnHomeTime() {
        let out = Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11)
        let back = Fixture.leg(Fixture.lax, Fixture.lhr, departLocal: Fixture.local(2026, 9, 12, 16), blockHours: 10)
        let trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        let strategy = decide(trip)
        #expect(strategy.kind == .stayOnHomeTime)
        #expect(strategy.direction == .none)
        #expect(strategy.targetShiftHours == 0)
        #expect(strategy.rationale.contains("shift back"))
    }

    @Test("A stay of intermediate length meets the local clock halfway")
    func intermediateStayShiftsPartially() {
        let out = Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11)
        let back = Fixture.leg(Fixture.lax, Fixture.lhr, departLocal: Fixture.local(2026, 9, 16, 16), blockHours: 10)
        let trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        let strategy = decide(trip)
        #expect(strategy.kind == .partialShift)
        #expect(abs(strategy.targetShiftHours) > 1)
        #expect(abs(strategy.targetShiftHours) < strategy.fullShiftMagnitude)
    }

    @Test("A long stay shifts all the way")
    func longStayShiftsFully() {
        let out = Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11)
        let back = Fixture.leg(Fixture.lax, Fixture.lhr, departLocal: Fixture.local(2026, 10, 1, 16), blockHours: 10)
        let trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        let strategy = decide(trip)
        #expect(strategy.kind == .fullShift)
        #expect(abs(strategy.targetShiftHours - strategy.fullShiftMagnitude * strategy.direction.sign) < 0.01)
    }

    @Test("An explicit override wins but is still explained")
    func overrideIsHonoured() {
        let out = Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11)
        let back = Fixture.leg(Fixture.lax, Fixture.lhr, departLocal: Fixture.local(2026, 9, 12, 16), blockHours: 10)
        var trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        trip.strategyOverride = .fullShift
        let strategy = decide(trip)
        #expect(strategy.kind == .fullShift)
        #expect(strategy.rationale.contains("You asked"))
    }

    @Test("An evening type is expected to delay faster than a morning type")
    func chronotypeChangesPacing() {
        var owl = Fixture.typicalSleeper; owl.chronotype = .definiteEvening
        var lark = Fixture.typicalSleeper; lark.chronotype = .definiteMorning
        let owlDelay = planner.dailyRate(for: .delay, sleeper: owl, options: PlanOptions())
        let larkDelay = planner.dailyRate(for: .delay, sleeper: lark, options: PlanOptions())
        #expect(owlDelay > larkDelay)

        let owlAdvance = planner.dailyRate(for: .advance, sleeper: owl, options: PlanOptions())
        let larkAdvance = planner.dailyRate(for: .advance, sleeper: lark, options: PlanOptions())
        #expect(larkAdvance > owlAdvance, "larks should advance more easily than owls")
    }

    @Test("An older traveller is expected to adapt more slowly")
    func ageBluntsResponse() {
        var young = Fixture.typicalSleeper; young.age = 25
        var older = Fixture.typicalSleeper; older.age = 70
        #expect(older.lightSensitivity < young.lightSensitivity)
        #expect(planner.dailyRate(for: .advance, sleeper: older, options: PlanOptions())
            < planner.dailyRate(for: .advance, sleeper: young, options: PlanOptions()))
    }
}
