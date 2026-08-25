import Foundation

/// Builds one day of the plan: places the windows, bends them around the user's real
/// commitments and the real sun, and reports how far the pacemaker actually moved.
struct DayBuilder {

    struct Outcome {
        var events: [PlanEvent] = []
        var netShift: Double = 0
        var notes: [String] = []
    }

    let slot: DaySlot
    var state: CircadianState
    /// Signed shift still outstanding at the start of the day.
    let remaining: Double
    let request: TripPlanRequest
    let strategy: ShiftStrategy
    let estimator: PhaseShiftEstimator

    private var sleeper: Sleeper { request.sleeper }
    private var options: PlanOptions { request.options }
    private var zoneID: String { slot.place.timeZoneIdentifier }

    /// Residual fraction of a light stimulus that gets through blue-blocking glasses,
    /// a hat and sitting away from the window. Deliberately conservative: mitigation
    /// helps, but it is not an eye mask.
    private static let mitigationResidual: Double = 0.35

    // MARK: - Build

    mutating func build() -> Outcome {
        var outcome = Outcome()
        var stimuli: [Stimulus] = []

        let direction = ShiftDirection(signedShift: remaining, threshold: 0.25)
        let plannedSleep = plannedSleepWindow(aim: remaining, direction: direction)

        addFlightEvents(to: &outcome)
        addStrategyMilestone(to: &outcome)

        if direction != .none {
            if let light = placeSeekLight(direction: direction, aim: remaining, sleep: plannedSleep) {
                stimuli.append(Stimulus(kind: .light(lux: light.lux), interval: light.interval))
                outcome.events.append(seekLightEvent(light, direction: direction))
                if let note = compromiseNote(for: light, kind: "bright-light") {
                    outcome.notes.append(note)
                }
            }

            let avoid = placeAvoidLight(direction: direction, sleep: plannedSleep)
            outcome.events.append(contentsOf: avoid.events)
            outcome.netShift += avoid.penalty
            outcome.notes.append(contentsOf: avoid.notes)

            if sleeper.usesMelatonin, let melatonin = placeMelatonin(direction: direction) {
                stimuli.append(Stimulus(
                    kind: .melatonin(milligrams: options.melatoninMilligrams),
                    interval: melatonin.interval
                ))
                outcome.events.append(melatoninEvent(melatonin, direction: direction))
            }
        }

        if direction == .none, strategy.kind != .noShiftNeeded,
           let anchor = anchorLightEvent(sleep: plannedSleep) {
            outcome.events.append(anchor)
        }

        outcome.events.append(sleepEvent(plannedSleep, direction: direction))
        if let nap = placeNap(sleep: plannedSleep) {
            outcome.events.append(nap)
        }
        if sleeper.usesCaffeine {
            outcome.events.append(contentsOf: caffeineEvents(sleep: plannedSleep))
        }

        // Free-running drift applies only while the clock is actually being moved.
        //
        // Someone settled on their habitual light–dark cycle is entrained, not
        // free-running: the usual morning commute already holds their phase, so adding a
        // drift term to a maintenance day would make an adapted plan oscillate forever.
        // Someone mid-shift is genuinely between entrainment states, and there the
        // intrinsic period is a real force — a τ of about 24.15 h is precisely why a
        // delay gets a tailwind and an advance fights a headwind, and it is what makes
        // the modelled delay rate exceed the advance rate the way the clinic expects.
        let net = estimator.netShift(
            stimuli: stimuli, state: state, sleeper: sleeper, includeDrift: direction != .none
        )
        outcome.netShift += net

        // Never plan past the goal: once the clock is where it needs to be, the plan's job
        // becomes holding it there, not overshooting.
        if direction != .none, abs(outcome.netShift) > abs(remaining), outcome.netShift * remaining > 0 {
            outcome.netShift = remaining
        }
        return outcome
    }

    // MARK: - Constraints

    private func constraints(_ kind: PracticalityConstraint.Kind) -> [(PracticalityConstraint, TimeWindow)] {
        request.constraints.compactMap { constraint in
            guard constraint.kind == kind else { return nil }
            guard let interval = constraint.resolve(
                dayIndex: slot.dayIndex,
                localDayStart: slot.localDayStart,
                calendar: slot.place.calendar
            ) else { return nil }
            return (constraint, interval)
        }
    }

    // MARK: - Light availability

    /// Time-weighted mean of the illuminance *factor* across a window, and whether the
    /// advice has to lean on artificial light.
    ///
    /// Sampling the factor rather than the lux matters: the dose–response saturates, so
    /// averaging raw lux across a window that is half daylight and half darkness would
    /// wildly overstate the dark half's contribution.
    private func lightAvailability(
        in window: TimeWindow,
        sleep: TimeWindow?
    ) -> (factor: Double, artificialShare: Double, blockedShare: Double) {
        let dose = estimator.doseResponse
        let usable = slot.solarDay.usableLight
        let unavoidable = constraints(.brightLightUnavoidable).map(\.1)
        let unavailable = constraints(.brightLightUnavailable).map(\.1)

        let stepSeconds: TimeInterval = 300
        var samples = 0
        var factorSum = 0.0
        var artificialSamples = 0
        var blockedSamples = 0
        // Samples where the eyes are actually open. The artificial/blocked shares have to
        // be fractions of *this*, not of the whole window: a window that is one third
        // daylight, one third asleep and one third lamp-lit is predominantly artificial,
        // and labelling it "go outside" would be wrong.
        var litSamples = 0

        var t = window.start
        while t < window.end {
            samples += 1
            let lux: Double
            if let sleep, sleep.contains(t) {
                lux = 0                                  // eyes shut: no stimulus
                factorSum += 0
                t = t.addingTimeInterval(stepSeconds)
                continue
            } else if unavailable.contains(where: { $0.contains(t) }) {
                lux = Illuminance.indoorDim               // windowless room, bad weather
                blockedSamples += 1
            } else if slot.solarDay.isPolarDay || (usable?.contains(t) ?? false) {
                lux = Illuminance.overcastDaylight        // outdoors, even under cloud
            } else if unavoidable.contains(where: { $0.contains(t) }) {
                lux = Illuminance.indoorBright
                artificialSamples += 1
            } else if options.allowArtificialBrightLight {
                lux = Illuminance.lightBox                // sun is down: therapy lamp
                artificialSamples += 1
            } else {
                lux = Illuminance.indoorDim
                blockedSamples += 1
            }
            litSamples += 1
            factorSum += dose.illuminanceFactor(lux: lux)
            t = t.addingTimeInterval(stepSeconds)
        }

        guard samples > 0 else { return (0, 0, 1) }
        let lit = max(litSamples, 1)
        return (
            factorSum / Double(samples),
            Double(artificialSamples) / Double(lit),
            Double(blockedSamples) / Double(lit)
        )
    }

    // MARK: - Seek light

    /// Places the bright-light window.
    ///
    /// Starts from the phase at which the published PRC produces the largest shift in the
    /// wanted direction, sizes the window from the duration–response law so it delivers
    /// only as much shift as is still needed, then searches a bounded neighbourhood for
    /// the best *actually achievable* placement given the sun and the user's day.
    private func placeSeekLight(
        direction: ShiftDirection,
        aim: Double,
        sleep: TimeWindow?
    ) -> FilteredWindow? {
        let idealPhase = estimator.optimalLightPhase(for: direction)
        let prcPeak = estimator.lightPRC.shift(atPhase: idealPhase)
        guard abs(prcPeak) > 1e-6 else { return nil }

        let dose = estimator.doseResponse
        // Duration needed to deliver `aim`, assuming near-saturating outdoor light.
        let outdoorFactor = dose.illuminanceFactor(lux: Illuminance.overcastDaylight)
        let requiredDurationFactor = abs(aim)
            / (abs(prcPeak) * outdoorFactor * sleeper.lightSensitivity * estimator.complianceFactor)
        var hours = dose.referenceDurationHours
            * pow(max(requiredDurationFactor, 1e-3), 1 / dose.durationExponent)
        hours = min(max(hours, options.minimumLightWindowHours), options.maximumLightWindowHours)

        let idealCentre = state.cbtMin.addingTimeInterval(idealPhase * 3600)
        let idealWindow = TimeWindow(
            start: idealCentre.addingTimeInterval(-hours / 2 * 3600),
            end: idealCentre.addingTimeInterval(hours / 2 * 3600)
        )
        let idealShift = prcPeak
            * dose.factor(lux: Illuminance.overcastDaylight, hours: hours)
            * sleeper.lightSensitivity * estimator.complianceFactor

        var best: FilteredWindow?
        var bestScore = -Double.infinity

        // Bounded search: ±4 h in quarter-hour steps. Beyond that the PRC has fallen far
        // enough that the advice stops being worth giving.
        for offsetQuarters in -16...16 {
            let offset = Double(offsetQuarters) / 4
            let shifted = idealWindow.shifted(byHours: offset)

            // Clip out the night. You cannot get light with your eyes shut, so prescribing
            // a window that runs into the sleep block would be advice nobody can follow —
            // and it would make the plan's own arithmetic optimistic. Keeping the longest
            // waking piece also makes the search naturally prefer offsets that clear the
            // night altogether.
            let candidate: TimeWindow
            if let sleep, shifted.intersects(sleep) {
                guard let piece = shifted.subtracting(sleep)
                    .max(by: { $0.durationHours < $1.durationHours }),
                      piece.durationHours >= options.minimumLightWindowHours else { continue }
                candidate = piece
            } else {
                candidate = shifted
            }

            let availability = lightAvailability(in: candidate, sleep: sleep)
            guard availability.factor > 0.05 else { continue }

            let lux = dose.equivalentLux(forFactor: availability.factor)
            let predicted = estimator.shift(
                for: Stimulus(kind: .light(lux: lux), interval: candidate),
                state: state,
                sleeper: sleeper
            )
            // Wrong sign means this placement would push the clock the wrong way.
            guard predicted * direction.sign > 0 else { continue }

            // Prefer the physiological optimum; move only when moving actually helps.
            let score = abs(predicted) - 0.02 * abs(offset)
            if score > bestScore {
                bestScore = score
                best = FilteredWindow(
                    interval: candidate,
                    predictedShift: predicted,
                    idealShift: idealShift,
                    movedBy: offset == 0 ? nil : reasonForMove(candidate: candidate, ideal: idealWindow),
                    lux: lux,
                    isArtificial: availability.artificialShare > 0.5
                )
            }
        }
        return best
    }

    /// Names whichever real-world factor is responsible for a window having moved.
    private func reasonForMove(candidate: TimeWindow, ideal: TimeWindow) -> String? {
        for (constraint, interval) in constraints(.brightLightUnavailable) where interval.intersects(ideal) {
            return constraint.label
        }
        for (constraint, interval) in constraints(.brightLightUnavoidable) where interval.intersects(ideal) {
            return constraint.label
        }
        if let usable = slot.solarDay.usableLight, !usable.intersects(ideal) {
            return "daylight hours"
        }
        if slot.solarDay.isPolarNight { return "polar night" }
        return "daylight hours"
    }

    private func seekLightEvent(_ window: FilteredWindow, direction: ShiftDirection) -> PlanEvent {
        let phase = state.phase(of: window.interval.midpoint)
        let relative = CircadianHours.signedOffset(phase)
        let position = relative >= 0
            ? String(format: "%.1f h after", relative)
            : String(format: "%.1f h before", -relative)

        var detail = direction == .advance
            ? "Bright light here pushes your body clock earlier. The window sits \(position) your body's temperature low point, which is where the phase-response curve peaks for advancing."
            : "Bright light here holds your body clock later. The window sits \(position) your temperature low point, on the delay side of the phase-response curve."

        if window.isArtificial {
            detail += " The sun is not up for this window, so use a 10,000 lux lamp or the brightest indoor light you have — expect roughly half the effect of daylight."
        } else {
            detail += " Outdoors is best: even an overcast sky is twenty times brighter than a well-lit room."
        }
        if let moved = window.movedBy {
            detail += " Moved to fit around \(moved)."
        }

        return PlanEvent(
            kind: window.isArtificial ? .seekArtificialLight : .seekLight,
            interval: window.interval,
            dayIndex: slot.dayIndex,
            title: window.isArtificial ? "Bright light indoors" : "Get bright light",
            detail: detail,
            displayTimeZoneIdentifier: zoneID,
            predictedShiftHours: window.predictedShift,
            adjustedForConstraint: window.movedBy,
            efficacy: window.efficacy,
            assumedLux: window.lux
        )
    }

    private func compromiseNote(for window: FilteredWindow, kind: String) -> String? {
        guard window.isCompromisedEnoughToMention else { return nil }
        return String(
            format: "Today's %@ window keeps only about %.0f%% of its ideal effect%@.",
            kind,
            window.efficacy * 100,
            window.movedBy.map { " because of \($0)" } ?? ""
        )
    }

    // MARK: - Avoid light

    /// The mirror image of the seek window: the phase where light would undo the day's
    /// work. Where the user has told us they cannot escape light there, the advice
    /// downgrades to mitigation and the residual wrong-way shift is charged against the
    /// day's progress rather than quietly ignored.
    private func placeAvoidLight(
        direction: ShiftDirection,
        sleep: TimeWindow?
    ) -> (events: [PlanEvent], penalty: Double, notes: [String]) {
        let worstPhase = estimator.worstLightPhase(for: direction)
        // Wider than the seek window: this is "dim everything for a while", not a dose.
        let hours = 4.0
        let centre = state.cbtMin.addingTimeInterval(worstPhase * 3600)
        let window = TimeWindow(
            start: centre.addingTimeInterval(-hours / 2 * 3600),
            end: centre.addingTimeInterval(hours / 2 * 3600)
        )

        // What full daylight in this window would cost, if you let it in.
        let counterfactual = estimator.shift(
            for: Stimulus(kind: .light(lux: Illuminance.overcastDaylight), interval: window),
            state: state,
            sleeper: sleeper
        )

        var events: [PlanEvent] = []
        var notes: [String] = []
        var penalty = 0.0

        let unavoidable = constraints(.brightLightUnavoidable).filter { $0.1.intersects(window) }

        // The portion we can genuinely keep dark, and that the traveller is awake for —
        // telling someone to avoid light while they are asleep is noise, not advice.
        var darkPieces = [window]
        if let sleep {
            darkPieces = darkPieces.flatMap { $0.subtracting(sleep) }
        }
        for (_, interval) in unavoidable {
            darkPieces = darkPieces.flatMap { $0.subtracting(interval) }
        }

        for piece in darkPieces where piece.durationHours > 0.25 {
            events.append(PlanEvent(
                kind: .avoidLight,
                interval: piece,
                dayIndex: slot.dayIndex,
                title: "Avoid bright light",
                detail: String(
                    format: "Light in this window works against you — it would pull your clock about %.1f h the wrong way. Sunglasses outdoors, blinds down, screens dim and warm.",
                    abs(counterfactual)
                ),
                displayTimeZoneIdentifier: zoneID,
                predictedShiftHours: 0,
                efficacy: 1,
                assumedLux: Illuminance.darkness
            ))
        }

        for (constraint, interval) in unavoidable {
            guard let overlap = interval.intersection(window), overlap.durationHours > 0.1 else { continue }
            let exposed = estimator.shift(
                for: Stimulus(kind: .light(lux: Illuminance.indoorBright), interval: overlap),
                state: state,
                sleeper: sleeper
            )
            let residual = exposed * Self.mitigationResidual
            penalty += residual
            events.append(PlanEvent(
                kind: .mitigateLight,
                interval: overlap,
                dayIndex: slot.dayIndex,
                title: "Dim what you can",
                detail: String(
                    format: "You told us you cannot avoid light during \(constraint.label). Blue-blocking glasses, a seat away from the windows and the lowest screen brightness you can work with cut most of it — expect to lose about %.1f h of today's progress rather than %.1f h.",
                    abs(residual), abs(exposed)
                ),
                displayTimeZoneIdentifier: zoneID,
                predictedShiftHours: residual,
                adjustedForConstraint: constraint.label,
                efficacy: 1 - Self.mitigationResidual,
                assumedLux: Illuminance.indoorBright * Self.mitigationResidual
            ))
            notes.append(String(
                format: "\(constraint.label) costs about %.1f h of today's shift.", abs(residual)
            ))
        }

        return (events, penalty, notes)
    }

    // MARK: - Melatonin

    private func placeMelatonin(direction: ShiftDirection) -> FilteredWindow? {
        let curve = options.melatoninMilligrams >= 1.5
            ? DualHarmonicPRC.burgess2008Melatonin3mg
            : DualHarmonicPRC.burgess2010Melatonin05mg
        let idealPhase = curve.phaseOfPeak(advance: direction == .advance)
        let ideal = state.dlmo.addingTimeInterval(idealPhase * 3600)
        let idealShift = curve.shift(atPhase: idealPhase)
            * sleeper.lightSensitivity * estimator.complianceFactor

        let blocked = constraints(.noMelatonin)
        if blocked.contains(where: { $0.0.isBlanket }) { return nil }

        var best: FilteredWindow?
        var bestScore = -Double.infinity
        // A dose is a point event; a 15-minute interval keeps it drawable on a timeline.
        for offsetQuarters in -8...8 {
            let offset = Double(offsetQuarters) / 4
            let start = ideal.addingTimeInterval(offset * 3600)
            let interval = TimeWindow(start: start, end: start.addingTimeInterval(900))
            if blocked.contains(where: { $0.1.intersects(interval) }) { continue }

            let predicted = estimator.shift(
                for: Stimulus(kind: .melatonin(milligrams: options.melatoninMilligrams), interval: interval),
                state: state,
                sleeper: sleeper
            )
            guard predicted * direction.sign > 0 else { continue }
            let score = abs(predicted) - 0.05 * abs(offset)
            if score > bestScore {
                bestScore = score
                best = FilteredWindow(
                    interval: interval,
                    predictedShift: predicted,
                    idealShift: idealShift,
                    movedBy: offset == 0 ? nil : blocked.first?.0.label,
                    lux: 0,
                    isArtificial: false
                )
            }
        }
        return best
    }

    private func melatoninEvent(_ window: FilteredWindow, direction: ShiftDirection) -> PlanEvent {
        let hoursToDLMO = -CircadianHours.signedOffset(
            state.dlmo.timeIntervalSince(window.interval.start) / 3600
        )
        let dose = options.melatoninMilligrams
        var detail = String(
            format: "Take %.1f mg about %.1f h %@ your melatonin onset. This is the timing the published melatonin phase-response curve puts the %@ peak at — a low dose acts as a timing signal, not a sleeping pill.",
            dose,
            abs(hoursToDLMO),
            hoursToDLMO < 0 ? "before" : "after",
            direction == .advance ? "advance" : "delay"
        )
        if let moved = window.movedBy { detail += " Moved to fit around \(moved)." }
        detail += " Melatonin is not regulated as a medicine everywhere and is prescription-only in some countries — check with a pharmacist or doctor first."

        return PlanEvent(
            kind: .melatonin,
            interval: window.interval,
            dayIndex: slot.dayIndex,
            title: String(format: "Melatonin %.1f mg", dose),
            detail: detail,
            displayTimeZoneIdentifier: zoneID,
            predictedShiftHours: window.predictedShift,
            adjustedForConstraint: window.movedBy,
            efficacy: window.efficacy
        )
    }

    // MARK: - Sleep

    /// Tonight's target sleep window.
    ///
    /// Light acts on where the clock *is*; sleep timing is a behavioural choice aimed at
    /// where the clock is *going*, so the window is placed at the phase expected at the
    /// end of the day and then pulled back inside anything the user must be awake for.
    private func plannedSleepWindow(aim: Double, direction: ShiftDirection) -> TimeWindow {
        let projected = state.applying(shiftHours: aim.clamped(to: -3...3))
        var window = projected.sleepWindow(for: sleeper)

        // `sleepWindow` is derived from CBTmin, which has been normalised into this local
        // day — so the window it returns is the night *ending* this morning. The night
        // that belongs to day D is the one whose bedtime falls on day D, so roll it
        // forward until the bedtime lands in [D 12:00, D+1 12:00).
        let noon = slot.localDayStart.addingTimeInterval(12 * 3600)
        while window.start < noon { window = window.shifted(byHours: 24) }
        while window.start >= noon.addingTimeInterval(24 * 3600) { window = window.shifted(byHours: -24) }

        for (_, interval) in constraints(.mustBeAwake) where interval.intersects(window) {
            // Give up the end of the night for an early commitment, the start for a late
            // one, whichever loses less sleep.
            let trimFront = TimeWindow(start: interval.end, end: window.end)
            let trimBack = TimeWindow(start: window.start, end: interval.start)
            window = trimFront.durationHours >= trimBack.durationHours ? trimFront : trimBack
        }
        return window
    }

    private func sleepEvent(_ window: TimeWindow, direction: ShiftDirection) -> PlanEvent {
        let hours = window.durationHours
        var detail: String
        switch strategy.kind {
        case .stayOnHomeTime:
            detail = "This is your home sleep window, kept deliberately even though the local clock disagrees. Blackout curtains and an eye mask are what make it possible."
        case .noShiftNeeded:
            detail = "Your usual night. No adjustment is needed for this trip."
        default:
            detail = direction == .advance
                ? "Tonight's target window, moved earlier as your clock advances. Lights down and screens off for the half hour before it starts."
                : direction == .delay
                    ? "Tonight's target window, held later as your clock delays. Stay up in bright light until it starts."
                    : "Your target window now that your clock has arrived where it needs to be."
        }
        if hours < sleeper.sleepDurationHours - 0.5 {
            detail += String(format: " Shortened to %.1f h by a commitment you told us about — a 20-minute nap earlier in the day will take the edge off.", hours)
        }
        return PlanEvent(
            kind: .sleep,
            interval: window,
            dayIndex: slot.dayIndex,
            title: "Sleep",
            detail: detail,
            displayTimeZoneIdentifier: zoneID,
            efficacy: hours >= sleeper.sleepDurationHours - 0.5 ? 1 : hours / sleeper.sleepDurationHours
        )
    }

    /// A short nap, offered only when the day is genuinely hard: a big outstanding shift,
    /// or a night that a commitment has cut short.
    private func placeNap(sleep: TimeWindow) -> PlanEvent? {
        let shortNight = sleep.durationHours < sleeper.sleepDurationHours - 1
        guard abs(remaining) >= 3 || shortNight else { return nil }

        // Aim at the post-lunch dip, ~7 h after *this* morning's wake time. `sleep.end` is
        // tomorrow morning, so step back a cycle to land on today's afternoon.
        let wake = sleep.end.addingTimeInterval(-24 * 3600)
        let ideal = wake.addingTimeInterval(7 * 3600)
        var interval = TimeWindow(start: ideal, end: ideal.addingTimeInterval(25 * 60))

        let awake = constraints(.mustBeAwake).map(\.1)
        for _ in 0..<8 where awake.contains(where: { $0.intersects(interval) }) {
            interval = interval.shifted(byHours: 0.5)
        }
        guard !awake.contains(where: { $0.intersects(interval) }) else { return nil }
        guard !interval.intersects(sleep) else { return nil }

        return PlanEvent(
            kind: .nap,
            interval: interval,
            dayIndex: slot.dayIndex,
            title: "Short nap",
            detail: "Twenty to thirty minutes, no longer — long enough to take the edge off, short enough to leave your night's sleep and your clock alone. Set an alarm.",
            displayTimeZoneIdentifier: zoneID
        )
    }

    /// Once the clock has arrived, the job changes from moving it to holding it there.
    ///
    /// Morning light is what keeps a schedule anchored, so adapted days get a short
    /// outdoor window rather than nothing at all — but only when the sun is actually up,
    /// because a notification telling you to go outside at 04:00 is worse than silence.
    private func anchorLightEvent(sleep: TimeWindow) -> PlanEvent? {
        // `sleep.end` is tomorrow morning; this day's morning is a cycle earlier.
        let wake = sleep.end.addingTimeInterval(-24 * 3600)
        let window = TimeWindow(
            start: wake.addingTimeInterval(1800),
            end: wake.addingTimeInterval(1800 + 3600)
        )
        guard let usable = slot.solarDay.usableLight,
              let overlap = window.intersection(usable),
              overlap.durationHours > 0.5 else { return nil }

        return PlanEvent(
            kind: .seekLight,
            interval: overlap,
            dayIndex: slot.dayIndex,
            title: "Anchor light",
            detail: strategy.kind == .stayOnHomeTime
                ? "Light shortly after your home-time wake keeps you anchored to home time while the local clock pulls the other way. Short and outdoors is enough."
                : "Your clock is where it needs to be. Light shortly after waking is what keeps it there — without it, it will start drifting later again.",
            displayTimeZoneIdentifier: zoneID,
            predictedShiftHours: nil,
            assumedLux: Illuminance.overcastDaylight
        )
    }

    // MARK: - Caffeine

    /// Caffeine does not move the clock in this model; it is scheduled purely to keep the
    /// traveller functional without wrecking the night that the plan depends on.
    ///
    /// The 8 h cut-off is conservative: Drake et al. (2013) found 400 mg six hours before
    /// bed still measurably disrupted sleep.
    private func caffeineEvents(sleep: TimeWindow) -> [PlanEvent] {
        let blocked = constraints(.noCaffeine)
        if blocked.contains(where: { $0.0.isBlanket }) { return [] }

        let cutoff = sleep.start.addingTimeInterval(-8 * 3600)
        let wake = sleep.end.addingTimeInterval(-24 * 3600)   // this morning, not tomorrow's
        var events: [PlanEvent] = []

        if wake < cutoff {
            var okWindow = TimeWindow(start: wake.addingTimeInterval(1800), end: cutoff)
            for (_, interval) in blocked {
                okWindow = okWindow.subtracting(interval).max(by: { $0.durationHours < $1.durationHours }) ?? okWindow
            }
            if okWindow.durationHours > 0.5 {
                events.append(PlanEvent(
                    kind: .caffeineOK,
                    interval: okWindow,
                    dayIndex: slot.dayIndex,
                    title: "Caffeine if you need it",
                    detail: "Safe window. Caffeine will not move your body clock, but it will get you through the local day — and a well-timed coffee is the difference between staying outside in bright light and going for a nap that undoes it.",
                    displayTimeZoneIdentifier: zoneID
                ))
            }
        }

        events.append(PlanEvent(
            kind: .caffeineAvoid,
            interval: TimeWindow(start: cutoff, end: sleep.start),
            dayIndex: slot.dayIndex,
            title: "No more caffeine",
            detail: "Stop now. Caffeine taken even six hours before bed measurably shortens and fragments sleep, and tonight's sleep is what the rest of the plan is built on.",
            displayTimeZoneIdentifier: zoneID
        ))
        return events
    }

    // MARK: - Flights and milestones

    private mutating func addFlightEvents(to outcome: inout Outcome) {
        if let flight = slot.outboundFlight {
            outcome.events.append(flightEvent(flight, isReturn: false))
        }
        if let flight = slot.returnFlight {
            outcome.events.append(flightEvent(flight, isReturn: true))
        }
    }

    private func flightEvent(_ flight: Flight, isReturn: Bool) -> PlanEvent {
        let hours = flight.blockTime / 3600
        var detail = String(
            format: "%@ to %@, about %.0f h in the air.",
            flight.origin.displayName, flight.destination.displayName, hours
        )
        // Cabin light is a real, controllable stimulus; say what to do with it.
        let worstPhase = estimator.worstLightPhase(for: strategy.direction)
        let worstCentre = state.cbtMin.addingTimeInterval(worstPhase * 3600)
        let worstWindow = TimeWindow(
            start: worstCentre.addingTimeInterval(-1.5 * 3600),
            end: worstCentre.addingTimeInterval(1.5 * 3600)
        )
        if let overlap = flight.interval.intersection(worstWindow), overlap.durationHours > 0.5 {
            detail += " Part of this flight falls in a window where cabin light would work against you — eye mask on, blind down, screen off."
        } else if strategy.direction != .none {
            let bestPhase = estimator.optimalLightPhase(for: strategy.direction)
            let bestCentre = state.cbtMin.addingTimeInterval(bestPhase * 3600)
            let bestWindow = TimeWindow(
                start: bestCentre.addingTimeInterval(-1.5 * 3600),
                end: bestCentre.addingTimeInterval(1.5 * 3600)
            )
            if let overlap = flight.interval.intersection(bestWindow), overlap.durationHours > 0.5 {
                detail += " Some of this flight falls in a useful light window — blind up, reading light on, and stay awake through it."
            }
        }
        return PlanEvent(
            kind: .flight,
            interval: flight.interval,
            dayIndex: slot.dayIndex,
            title: isReturn ? "Flight home" : "Flight",
            detail: detail,
            displayTimeZoneIdentifier: flight.destination.timeZoneIdentifier
        )
    }

    private func addStrategyMilestone(to outcome: inout Outcome) {
        guard slot.isArrivalDay else { return }
        let title: String
        switch strategy.kind {
        case .stayOnHomeTime: title = "Staying on home time"
        case .noShiftNeeded: title = "No adjustment needed"
        case .partialShift: title = "Meeting the local clock halfway"
        case .fullShift: title = "Adapting to local time"
        }
        let arrival = slot.outboundFlight?.arrival ?? slot.localDayStart
        outcome.events.append(PlanEvent(
            kind: .milestone,
            interval: TimeWindow(start: arrival, end: arrival.addingTimeInterval(900)),
            dayIndex: slot.dayIndex,
            title: title,
            detail: strategy.rationale,
            displayTimeZoneIdentifier: zoneID
        ))
    }
}

// MARK: - Small helpers

extension FilteredWindow {
    var isCompromisedEnoughToMention: Bool { efficacy < 0.85 }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
