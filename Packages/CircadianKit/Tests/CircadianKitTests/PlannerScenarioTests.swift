import Testing
import Foundation
@testable import CircadianKit

@Suite("Planner scenarios")
struct PlannerScenarioTests {

    let planner = CircadianPlanner()

    // MARK: - Eastward

    @Test("Multi-day eastward trip advances the clock and converges on local time")
    func multiDayEastward() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.cdg, departLocal: Fixture.local(2026, 9, 10, 19), blockHours: 7),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)

        #expect(plan.strategy.direction == .advance)
        #expect(plan.achievedShiftHours > 0, "an advance must be a positive shift")
        #expect(abs(plan.residualMisalignmentHours) < 0.75, "residual \(plan.residualMisalignmentHours) h")
        let adaptationDay = try! #require(plan.dayAdaptationReached)
        #expect(adaptationDay > 0 && adaptationDay <= 8, "adapted on day \(adaptationDay)")

        // Progress must be monotone towards the goal, never oscillating, and must stay
        // there once reached rather than drifting back off.
        let remaining = plan.days.map(\.remainingShiftHours)
        for (earlier, later) in zip(remaining, remaining.dropFirst()) {
            #expect(abs(later) <= abs(earlier) + 0.001, "went backwards: \(earlier) -> \(later)")
        }

        // Every shifting light window must sit on the advance side of the temperature
        // minimum. Maintenance windows once adapted carry no predicted shift and are
        // exempt: their job is to hold phase, not move it.
        for day in plan.days {
            let state = CircadianState(cbtMin: day.cbtMinAtStart)
            for event in day.events where event.kind == .seekLight || event.kind == .seekArtificialLight {
                guard let shift = event.predictedShiftHours else { continue }
                let phase = state.phase(of: event.interval.midpoint)
                #expect(phase > 0 && phase < 12, "light at phase \(phase) should be post-CBTmin for an advance")
                #expect(shift > 0)
            }
        }

        // Adaptation should take roughly the number of days the strategy promised.
        let expected = plan.strategy.estimatedDaysToAdapt
        let actualDays = Double(adaptationDay + trip.options.preflightDays)
        #expect(actualDays <= expected * 1.6 + 1, "promised ~\(expected) days, took \(actualDays)")
    }

    @Test("Eastward plan starts preparing before departure")
    func eastwardPreparesEarly() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.nrt, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 14),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        let preflight = plan.days.filter { $0.dayIndex < 0 }
        #expect(preflight.count == 3)
        #expect(preflight.allSatisfy { !$0.events.isEmpty })
        #expect(preflight.contains { day in day.events.contains { $0.kind == .seekLight || $0.kind == .seekArtificialLight } })
    }

    // MARK: - Westward

    @Test("Multi-day westward trip delays the clock and converges")
    func multiDayWestward() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)

        #expect(plan.strategy.direction == .delay)
        #expect(plan.achievedShiftHours < 0, "a delay must be a negative shift")
        #expect(abs(plan.residualMisalignmentHours) < 0.75, "residual \(plan.residualMisalignmentHours) h")

        for day in plan.days {
            let state = CircadianState(cbtMin: day.cbtMinAtStart)
            for event in day.events where event.kind == .seekLight || event.kind == .seekArtificialLight {
                guard let shift = event.predictedShiftHours else { continue }
                let phase = state.phase(of: event.interval.midpoint)
                #expect(phase > 12, "light at phase \(phase) should be pre-CBTmin for a delay")
                #expect(shift < 0)
            }
        }
    }

    @Test("A delay is achieved faster per day than an advance of the same size")
    func delaysAreFasterThanAdvances() {
        // Two 8 h shifts of opposite sign, so the comparison is like for like.
        let east = planner.makePlan(for: TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.nrt, departLocal: Fixture.local(2026, 9, 10, 13), blockHours: 12),
            sleeper: Fixture.typicalSleeper
        ))
        let west = planner.makePlan(for: TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11),
            sleeper: Fixture.typicalSleeper
        ))
        #expect(east.strategy.direction == .advance)
        #expect(west.strategy.direction == .delay)
        #expect(abs(east.strategy.fullShiftMagnitude - 8) < 0.01)
        #expect(abs(west.strategy.fullShiftMagnitude - 8) < 0.01)

        // The delay lobe of the PRC is larger than the advance lobe, so the best day of a
        // delay plan must beat the best day of an advance plan.
        let bestAdvance = east.days.map { abs($0.achievedShiftHours) }.max()!
        let bestDelay = west.days.map { abs($0.achievedShiftHours) }.max()!
        #expect(bestDelay > bestAdvance, "delay \(bestDelay) h/day vs advance \(bestAdvance) h/day")

        // And the whole 8 h should therefore take fewer days.
        let eastDays = try! #require(east.dayAdaptationReached)
        let westDays = try! #require(west.dayAdaptationReached)
        #expect(westDays <= eastDays)
    }

    // MARK: - No-op

    @Test("A short hop across one zone produces no light or melatonin prescriptions")
    func shortHopIsANoOp() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.cdg, departLocal: Fixture.local(2026, 9, 10, 9), blockHours: 1.25),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)

        #expect(plan.strategy.kind == .noShiftNeeded)
        #expect(plan.lightEvents.isEmpty, "no light windows for a no-op trip")
        #expect(plan.events(.avoidLight).isEmpty)
        #expect(plan.events(.melatonin).isEmpty, "never prescribe melatonin when no shift is needed")
        #expect(abs(plan.achievedShiftHours) < 0.01)
        // It should still be a usable plan: sleep windows and the flight remain.
        #expect(!plan.events(.sleep).isEmpty)
        #expect(!plan.events(.flight).isEmpty)
    }

    @Test("A no-op plan explains itself rather than showing an empty screen")
    func noOpExplainsItself() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.dub, departLocal: Fixture.local(2026, 9, 10, 9), blockHours: 1.25),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        #expect(!plan.strategy.rationale.isEmpty)
        #expect(plan.events(.milestone).contains { $0.detail == plan.strategy.rationale })
    }

    // MARK: - Quick turnaround

    @Test("Quick turnaround keeps the traveller on home time throughout")
    func quickTurnaroundHoldsHomePhase() {
        let out = Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 11)
        let back = Fixture.leg(Fixture.lax, Fixture.lhr, departLocal: Fixture.local(2026, 9, 12, 16), blockHours: 10)
        let trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        let plan = planner.makePlan(for: trip)

        #expect(plan.strategy.kind == .stayOnHomeTime)
        // The clock must barely move over the whole trip — that is the whole point.
        #expect(abs(plan.achievedShiftHours) < 1.0, "drifted \(plan.achievedShiftHours) h")

        // Sleep windows at the destination should still be at home-time hours, which means
        // they land at odd-looking local clock times in Los Angeles.
        let destinationDays = plan.days.filter { $0.place.iata == "LAX" }
        #expect(!destinationDays.isEmpty)
        for day in destinationDays {
            guard let sleep = day.events.first(where: { $0.kind == .sleep }) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Fixture.lhr.timeZone
            let hour = cal.component(.hour, from: sleep.interval.start)
            // Bedtime should still be London-evening-ish, not Los Angeles evening.
            #expect(hour >= 21 || hour <= 1, "home bedtime drifted to \(hour):00 London time")
        }
        #expect(plan.events(.milestone).contains { $0.title.contains("home time") })
    }

    @Test("Quick turnaround still gives protective advice, not an empty plan")
    func quickTurnaroundStillAdvises() {
        let out = Fixture.leg(Fixture.lhr, Fixture.jfk, departLocal: Fixture.local(2026, 9, 10, 9), blockHours: 8)
        let back = Fixture.leg(Fixture.jfk, Fixture.lhr, departLocal: Fixture.local(2026, 9, 11, 19), blockHours: 7)
        let trip = TripPlanRequest(outbound: out, homebound: back, sleeper: Fixture.typicalSleeper)
        let plan = planner.makePlan(for: trip)
        #expect(plan.strategy.kind == .stayOnHomeTime)
        #expect(!plan.events(.sleep).isEmpty)
        #expect(!plan.events(.caffeineOK).isEmpty, "caffeine timing is how you survive a quick turnaround")
    }

    // MARK: - DST

    @Test("A trip spanning a daylight-saving transition uses the right offset on each side")
    func dstTransitionChangesTheZoneDifference() {
        // Britain leaves BST on 25 October 2026; the United States stays on EDT until
        // 1 November. So London to New York is a 5 h change before the 25th and 4 h after.
        let before = Fixture.leg(Fixture.lhr, Fixture.jfk, departLocal: Fixture.local(2026, 10, 20, 11), blockHours: 8)
        let after = Fixture.leg(Fixture.lhr, Fixture.jfk, departLocal: Fixture.local(2026, 10, 28, 11), blockHours: 8)
        #expect(abs(before.rawZoneDifferenceHours + 5) < 0.01, "got \(before.rawZoneDifferenceHours)")
        #expect(abs(after.rawZoneDifferenceHours + 4) < 0.01, "got \(after.rawZoneDifferenceHours)")
    }

    @Test("Local days remain correct across a clocks-go-back transition")
    func dstTransitionProducesA25HourDay() {
        // Depart on the 27th with three preparation days, so the plan spans the 25th.
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.jfk, departLocal: Fixture.local(2026, 10, 27, 11), blockHours: 8),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        let londonDays = plan.days.filter { $0.place.iata == "LHR" }.map(\.localDayStart).sorted()
        let gaps = zip(londonDays, londonDays.dropFirst()).map { $1.timeIntervalSince($0) / 3600 }
        #expect(gaps.contains { abs($0 - 25) < 0.01 }, "expected a 25 h day, got \(gaps)")
        #expect(gaps.allSatisfy { $0 >= 23 && $0 <= 25 })

        // Every day's local midnight must genuinely be midnight in its own zone.
        for day in plan.days {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = day.place.timeZone
            let components = cal.dateComponents([.hour, .minute], from: day.localDayStart)
            #expect(components.hour == 0 && components.minute == 0,
                    "day \(day.dayIndex) starts at \(components.hour!):\(components.minute!)")
        }
    }

    @Test("A trip into the southern hemisphere across the equator still converges")
    func southernHemisphereTrip() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.syd, departLocal: Fixture.local(2026, 1, 15, 21), blockHours: 22),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        #expect(plan.strategy.kind == .fullShift)
        #expect(abs(plan.residualMisalignmentHours) < 1.5, "residual \(plan.residualMisalignmentHours)")
    }

    // MARK: - Structural invariants

    @Test("Outdoor light windows never fall outside usable daylight")
    func outdoorAdviceRespectsTheSun() {
        for (origin, destination, month) in [
            (Fixture.lhr, Fixture.lax, 12),
            (Fixture.jfk, Fixture.nrt, 6),
            (Fixture.lhr, Fixture.place("SIN"), 3)
        ] {
            let trip = TripPlanRequest(
                outbound: Fixture.leg(origin, destination, departLocal: Fixture.local(2026, month, 12, 10), blockHours: 12),
                sleeper: Fixture.typicalSleeper
            )
            let plan = planner.makePlan(for: trip)
            for day in plan.days {
                let solar = day.place.solarDay(containing: day.localDayStart.addingTimeInterval(12 * 3600))
                guard let usable = solar.usableLight else { continue }
                for event in day.events where event.kind == .seekLight {
                    // An outdoor prescription must overlap real daylight substantially.
                    let overlap = event.interval.intersection(usable)?.durationHours ?? 0
                    #expect(overlap / event.interval.durationHours > 0.5,
                            "\(origin.iata)->\(destination.iata) day \(day.dayIndex): only \(overlap) h of \(event.interval.durationHours) h in daylight")
                }
            }
        }
    }

    @Test("Events are ordered, non-degenerate and carry a usable notification body")
    func eventsAreWellFormed() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.nrt, departLocal: Fixture.local(2026, 5, 3, 13), blockHours: 12),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        #expect(!plan.events.isEmpty)
        let starts = plan.events.map(\.interval.start)
        #expect(starts == starts.sorted())
        for event in plan.events {
            #expect(event.interval.durationHours > 0, "\(event.kind) has zero duration")
            #expect(!event.title.isEmpty)
            #expect(event.detail.count > 20, "\(event.kind) detail is too thin to notify with")
            #expect(TimeZone(identifier: event.displayTimeZoneIdentifier) != nil)
        }
    }

    @Test("Sleep windows are a plausible length and one per day")
    func sleepWindowsAreSane() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.lhr, Fixture.lax, departLocal: Fixture.local(2026, 7, 4, 11), blockHours: 11),
            sleeper: Fixture.typicalSleeper
        )
        let plan = planner.makePlan(for: trip)
        for day in plan.days {
            let sleeps = day.events.filter { $0.kind == .sleep }
            #expect(sleeps.count == 1, "day \(day.dayIndex) has \(sleeps.count) sleep windows")
            let hours = sleeps[0].interval.durationHours
            #expect(hours > 5 && hours < 11, "day \(day.dayIndex) sleep is \(hours) h")
            // Bedtime must land on the day it belongs to.
            #expect(sleeps[0].interval.start >= day.localDayStart.addingTimeInterval(12 * 3600))
            #expect(sleeps[0].interval.start < day.localDayStart.addingTimeInterval(36 * 3600))
        }
    }

    @Test("A plan is deterministic")
    func planIsDeterministic() {
        let trip = TripPlanRequest(
            outbound: Fixture.leg(Fixture.jfk, Fixture.nrt, departLocal: Fixture.local(2026, 9, 10, 11), blockHours: 14),
            sleeper: Fixture.typicalSleeper
        )
        let a = planner.makePlan(for: trip)
        let b = planner.makePlan(for: trip)
        #expect(a.days.map(\.achievedShiftHours) == b.days.map(\.achievedShiftHours))
        #expect(a.events.map(\.interval) == b.events.map(\.interval))
    }
}
