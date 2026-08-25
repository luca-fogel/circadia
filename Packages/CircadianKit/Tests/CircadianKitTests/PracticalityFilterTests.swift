import Testing
import Foundation
@testable import CircadianKit

@Suite("Practicality filter")
struct PracticalityFilterTests {

    let planner = CircadianPlanner()

    /// London to Los Angeles: an 8 h delay, so the ideal light window lands in the evening.
    func westwardTrip(constraints: [PracticalityConstraint]) -> TripPlanRequest {
        TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 6, 15, 11), blockHours: 11),
            sleeper: Fixture.typicalSleeper,
            constraints: constraints
        )
    }

    /// New York to Paris: a 6 h advance, so the ideal light window lands in the morning.
    func eastwardTrip(constraints: [PracticalityConstraint]) -> TripPlanRequest {
        TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.cdg, departLocal: Fixture.local(2026, 6, 15, 19), blockHours: 7),
            sleeper: Fixture.typicalSleeper,
            constraints: constraints
        )
    }

    @Test("With no constraints the light window sits on the PRC peak")
    func unconstrainedWindowIsOptimal() {
        let plan = planner.makePlan(for: eastwardTrip(constraints: []))
        let shifting = plan.lightEvents.filter { $0.predictedShiftHours != nil }
        #expect(!shifting.isEmpty)
        #expect(shifting.allSatisfy { $0.adjustedForConstraint == nil })
        #expect(shifting.allSatisfy { $0.efficacy > 0.95 })
        #expect(plan.compromisedEventCount == 0)
    }

    @Test("A morning meeting that blocks bright light moves the window and says so")
    func blockedMorningLightMovesTheWindow() {
        // The ideal advance window is around 08:00–09:00; block exactly that.
        let constraint = PracticalityConstraint(
            kind: .brightLightUnavailable,
            from: ClockTime(hour: 6),
            to: ClockTime(hour: 10),
            label: "windowless 7am stand-up"
        )
        let constrained = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        let baseline = planner.makePlan(for: eastwardTrip(constraints: []))

        let moved = constrained.lightEvents.filter { $0.adjustedForConstraint != nil }
        #expect(!moved.isEmpty, "the filter should have moved at least one window")
        #expect(moved.allSatisfy { $0.adjustedForConstraint == "windowless 7am stand-up" })
        #expect(moved.allSatisfy { $0.detail.contains("windowless 7am stand-up") })

        // Still the right direction, just less effective — never silently abandoned.
        #expect(constrained.strategy.direction == .advance)
        #expect(constrained.lightEvents.compactMap(\.predictedShiftHours).allSatisfy { $0 > 0 })
        #expect(abs(constrained.achievedShiftHours) <= abs(baseline.achievedShiftHours) + 0.01)
    }

    @Test("Windows are nudged within physiological bounds, not thrown anywhere")
    func nudgesStayWithinBounds() {
        let constraint = PracticalityConstraint(
            kind: .brightLightUnavailable,
            from: ClockTime(hour: 6),
            to: ClockTime(hour: 10),
            label: "no window"
        )
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        for day in plan.days {
            let state = CircadianState(cbtMin: day.cbtMinAtStart)
            for event in day.events where event.kind == .seekLight || event.kind == .seekArtificialLight {
                guard event.predictedShiftHours != nil else { continue }
                let phase = state.phase(of: event.interval.midpoint)
                // The search is bounded to +/-4 h around the 4.05 h advance peak, and must
                // never cross to the delay side of the temperature minimum.
                #expect(phase > 0 && phase <= 8.1, "phase \(phase) escaped the allowed band")
            }
        }
    }

    @Test("Light you cannot avoid becomes mitigation advice and is charged against progress")
    func unavoidableLightIsChargedNotIgnored() {
        // For a delay, the window to protect is in the morning; put a lit office there.
        let constraint = PracticalityConstraint(
            kind: .brightLightUnavoidable,
            from: ClockTime(hour: 7),
            to: ClockTime(hour: 12),
            label: "open-plan office"
        )
        let constrained = planner.makePlan(for: westwardTrip(constraints: [constraint]))
        let baseline = planner.makePlan(for: westwardTrip(constraints: []))

        let mitigations = constrained.events(.mitigateLight)
        #expect(!mitigations.isEmpty, "should offer mitigation rather than an impossible instruction")
        #expect(mitigations.allSatisfy { $0.adjustedForConstraint == "open-plan office" })
        #expect(mitigations.allSatisfy { ($0.predictedShiftHours ?? 0) > 0 },
                "residual exposure works against a delay, so it must be a positive (advance) penalty")

        // The cost must show up as slower progress. Both plans still reach the goal
        // eventually, so the tell is that the constrained one takes longer to get there.
        let constrainedDay = try! #require(constrained.dayAdaptationReached)
        let baselineDay = try! #require(baseline.dayAdaptationReached)
        #expect(constrainedDay > baselineDay,
                "adapted on day \(constrainedDay) constrained vs \(baselineDay) free")
        #expect(constrained.days.contains { $0.notes.contains { $0.contains("open-plan office") } })
    }

    @Test("A commitment that overlaps the night shortens sleep and offers a nap")
    func mustBeAwakeShortensSleepAndAddsANap() {
        let constraint = PracticalityConstraint(
            kind: .mustBeAwake,
            from: ClockTime(hour: 5),
            to: ClockTime(hour: 8),
            label: "early call with head office"
        )
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        let sleeps = plan.events(.sleep)
        #expect(!sleeps.isEmpty)
        // No sleep window may overlap the commitment.
        for sleep in sleeps {
            for day in plan.days where day.dayIndex == sleep.dayIndex {
                guard let window = constraint.resolve(
                    dayIndex: day.dayIndex, localDayStart: day.localDayStart, calendar: day.place.calendar
                ) else { continue }
                #expect(!sleep.interval.intersects(window), "sleep runs through the call")
            }
        }
        #expect(!plan.events(.nap).isEmpty, "a shortened night should earn a nap")
        #expect(plan.events(.nap).allSatisfy { $0.interval.durationHours < 0.75 })
    }

    @Test("A blanket no-melatonin constraint removes every dose")
    func melatoninCanBeRefusedOutright() {
        let constraint = PracticalityConstraint(
            kind: .noMelatonin,
            from: ClockTime(hour: 0),
            to: ClockTime(hour: 0),
            label: "pregnant — avoiding supplements"
        )
        #expect(constraint.isBlanket)
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        #expect(plan.events(.melatonin).isEmpty)
        // The plan must still work, just more slowly.
        #expect(plan.strategy.direction == .advance)
        #expect(!plan.lightEvents.isEmpty)
    }

    @Test("A blanket no-caffeine constraint removes caffeine guidance")
    func caffeineCanBeRefusedOutright() {
        let constraint = PracticalityConstraint(
            kind: .noCaffeine, from: ClockTime(hour: 0), to: ClockTime(hour: 0), label: "no caffeine"
        )
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        #expect(plan.events(.caffeineOK).isEmpty)
        #expect(plan.events(.caffeineAvoid).isEmpty)
    }

    @Test("A constraint scoped to one day only affects that day")
    func daysScopedConstraintIsLocal() {
        let constraint = PracticalityConstraint(
            kind: .brightLightUnavailable,
            dayIndex: 1,
            from: ClockTime(hour: 5),
            to: ClockTime(hour: 12),
            label: "day one conference"
        )
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        let adjusted = plan.events.filter { $0.adjustedForConstraint == "day one conference" }
        #expect(!adjusted.isEmpty)
        #expect(adjusted.allSatisfy { $0.dayIndex == 1 })
    }

    @Test("Efficacy loss is reported rather than hidden")
    func efficacyIsReported() {
        let constraint = PracticalityConstraint(
            kind: .brightLightUnavailable,
            from: ClockTime(hour: 4),
            to: ClockTime(hour: 13),
            label: "all-day windowless conference"
        )
        let plan = planner.makePlan(for: eastwardTrip(constraints: [constraint]))
        #expect(plan.compromisedEventCount > 0, "a nine-hour blackout must cost something visible")
        let compromised = plan.events.filter(\.isCompromised)
        #expect(compromised.allSatisfy { $0.efficacy < 0.85 })
        #expect(compromised.allSatisfy { $0.efficacy >= 0 })
        // And the plan should take longer than the unconstrained version.
        let baseline = planner.makePlan(for: eastwardTrip(constraints: []))
        let slow = try! #require(plan.dayAdaptationReached)
        let fast = try! #require(baseline.dayAdaptationReached)
        #expect(slow > fast, "adapted on day \(slow) constrained vs \(fast) free")
    }

    @Test("Even a heavily constrained plan never prescribes the wrong direction")
    func neverPrescribesBackwards() {
        let constraints = [
            PracticalityConstraint(kind: .brightLightUnavailable, from: ClockTime(hour: 4), to: ClockTime(hour: 14), label: "conference"),
            PracticalityConstraint(kind: .brightLightUnavoidable, from: ClockTime(hour: 19), to: ClockTime(hour: 23), label: "dinners"),
            PracticalityConstraint(kind: .mustBeAwake, from: ClockTime(hour: 6), to: ClockTime(hour: 8), label: "calls")
        ]
        for trip in [eastwardTrip(constraints: constraints), westwardTrip(constraints: constraints)] {
            let plan = planner.makePlan(for: trip)
            let sign = plan.strategy.direction.sign
            for event in plan.lightEvents {
                guard let shift = event.predictedShiftHours else { continue }
                #expect(shift * sign > 0, "\(event.kind) pushes the wrong way")
            }
        }
    }
}
