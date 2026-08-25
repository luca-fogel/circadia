# Deviations from the brief

Everywhere the implementation departs from the plan as specified, with the reason. Ordered
roughly by how much it matters.

## 1. There is no hard "dead zone" by default — the evidence does not support one

The brief asked for a light-response curve with "a genuine *dead zone* in mid-subjective-day".
The best-quality human PRC explicitly reports the opposite. Khalsa et al. (2003), the
6.7 h bright-light study the curve is otherwise built from, states:

> there is no evidence of a significant dead zone in this study... phase advances diminish
> gradually during the course of the early subjective day, ultimately yielding to gradually
> increasing phase delays later in the subjective day.

So the shipped curve has a **low-sensitivity subjective day** — continuous, monotonically
decaying from the advance peak, crossing zero near circadian phase 12 — rather than a flat
region pinned at zero. `PhaseResponseCurveTests.noHardDeadZoneByDefault` asserts the
paper's actual claims: monotone decay, and no phase at which the response is exactly zero.

A hard dead zone is still available, because limit-cycle models of the pacemaker
(Kronauer/Jewett) and most non-human PRCs do include one and comparing them is instructive:

```swift
CircadianPlanner(prcVariant: .deadZone(from: 7, to: 14, attenuation: 0))
```

**This is the one place where I have implemented something different from what was asked,
rather than something more than what was asked.** It seemed better than encoding a feature
the primary source denies.

## 2. The chronotype → CBTmin relationship is inverted relative to the old code

The previous `JetLagModel` had:

```swift
case .early:  return -1.5   // CBTmin further before wake
case .late:   return -2.5
```

The comment and the numbers disagree, and the numbers are backwards. Duffy, Rimmer &
Czeisler (2001) found **morning** types entrain with a *longer* interval between the
temperature nadir and wake-up; evening types wake at an earlier circadian phase because
social schedules truncate their biological night. The new values run from 3.2 h for a
definite morning type down to 1.4 h for a definite evening type. This changes the sign of
every chronotype effect in the app, so it is worth being explicit about.

## 3. Direction is chosen by cost, which sometimes contradicts the direction of travel

The brief asked for eastward and westward handling. Implemented, but not as
"east ⇒ advance, west ⇒ delay": a `d`-hour eastward change can be met by advancing `d`
hours *or* delaying `24 − d`, and because delays are cheaper the second is sometimes fewer
days. New York → Tokyo (13 h east) is planned as an **11 h delay**. The strategy carries an
`isCounterIntuitiveDirection` flag and explains itself in prose, because otherwise the
advice looks like a bug to the user.

## 4. The PRC is evaluated as a pulse response, not integrated as a sensitivity density

The published curves describe *one discrete pulse per circadian cycle*, plotted against the
phase of the pulse's **centre**. The obvious-looking move — treating the curve as a
sensitivity density and integrating it over an arbitrary window — would double-count
duration, since duration already has its own strongly sub-linear law.

So each prescribed window is scored as a pulse: the curve is evaluated at the window's
midpoint and scaled for brightness and duration. This is more faithful to the measurement,
and it handles the awkward case correctly (a window centred on CBTmin nets ~zero). Its
limitation is that a single window straddling the crossover is treated as one stimulus
rather than as competing halves. Multiple windows in a day are summed and then squashed
through a `tanh` limiter, because responses do not add linearly.

## 5. A compliance factor of 0.5 separates laboratory numbers from real-world ones

The PRCs come from inpatient protocols: constant routine, controlled dim background light,
a compliant subject in front of a light box for 6.7 hours. Applying them raw made the
simulation predict **2.1 h/day** of advance, roughly double what the clinical literature
expects, and put the simulation at odds with the pacing its own strategy layer had used to
choose the strategy.

Every predicted shift is therefore scaled by `PlanOptions.complianceFactor` (default 0.5),
and the number shown to the user is the scaled one. As noted in the README, this plus the
intrinsic-period drift reproduces the ~1 h/day and ~1.5 h/day rules of thumb from the
published amplitudes, which is reassuring but was not the design target.

## 6. Free-running drift applies only while the clock is actively being moved

Including the τ ≈ 24.15 h drift on every day made adapted plans **oscillate forever**: the
clock would drift 0.15 h later, cross the 0.25 h threshold after two days, get corrected,
and repeat. Excluding it everywhere made delays no easier than advances, contradicting both
the clinic and the physiology.

The resolution is that the term is only physical when it applies: a person settled on their
habitual light–dark cycle is entrained, not free-running, and their usual morning commute
holds their phase. A person mid-shift genuinely is between entrainment states. Drift is
therefore included when a shift is in progress and omitted on maintenance days, which get a
short "anchor light" window instead.

## 7. Solar position uses bundled airport coordinates, not CoreLocation

The brief suggested "CoreLocation + a solar position calculation". The solar calculation is
implemented in full (NOAA/Meeus, validated against equinox day length, solar-noon symmetry,
seasonal sign, and polar day/night). The coordinates come from the **bundled airport
database** rather than CoreLocation, because:

- the plan needs the *destination's* sunrise, which CoreLocation cannot give you until you
  are already there — and the whole point is planning days in advance;
- it works with no signal, which is the situation on a plane;
- it needs no location permission.

CoreLocation is still there, in `LocationProvider`, doing the one job it is actually suited
to: a single optional lookup to pre-select the departure airport. Nothing is stored.

## 8. Two published values were not available and had to be reconstructed

- **St Hilaire et al. (2012)** publish the 1 h curve's peak-to-trough amplitude (2.20 h)
  but not its extremum phases. `stHilaire2012Light` reuses Khalsa's extremum phases and
  scales the amplitudes, preserving Khalsa's advance:delay ratio. Only the amplitude is
  load-bearing — it is what the duration law is fitted to.
- **Melatonin PRC timings** are read from the papers' prose (advances maximal for afternoon
  dosing a few hours before DLMO, earlier for 3 mg than for 0.5 mg) rather than from a
  coefficient table, which is not published. Amplitudes come from Burgess et al. (2008)'s
  three-pulse protocol and are divided by three to express a per-dose shift, since the
  planner administers one dose per day and sums across days itself.

Neither paper publishes its dual-harmonic coefficients, so `DualHarmonicPRC` recovers them
by solving the 4×4 system that forces the curve through the published extrema as stationary
points. This reproduces the published maxima exactly and lets the shape between them follow
the papers' own functional form. Tests assert the fit does not overshoot the published peaks.

## 9. The age–sensitivity function is an invention

Older adults show a blunted phase-shifting response to light, but there is no single agreed
dose–age function. `Sleeper.lightSensitivity` is flat below 40 and then declines gently to a
floor of 0.65 — deliberately conservative, and flagged here because it is the one
quantitative relationship in the engine with no specific citation behind it.

## 10. Caffeine is scheduled, but is not modelled as moving the clock

Caffeine does have circadian effects, but modelling them properly is a separate research
problem. Here it is scheduled purely for alertness and for protecting the night the plan
depends on, with a conservative 8 h pre-bed cut-off (Drake et al. 2013 found 400 mg six
hours before bed still measurably disrupted sleep). `PlanEvent.predictedShiftHours` is
`nil` for caffeine events, so it never contributes to the arithmetic.

## 11. Notifications are budgeted, because iOS silently drops the overflow

iOS keeps at most **64 pending local notifications per app**. A two-week plan generates far
more events than that, and the excess is dropped without an error. `NotificationScheduler`
therefore ranks events by importance (light windows > sleep > melatonin > naps > caffeine)
and spends a 60-notification budget on the top of the list, so an over-long plan loses its
caffeine reminders on day nine rather than its light window tomorrow morning. The plan
screen says so when it happens.

## 12. Smaller decisions worth knowing about

- **The app is called Circadia**, not Timeshifter. The name and the icon keep a clear
  distance from a trademark, and the disclaimer names the product it is *not*.
- **One multiplatform target**, not separate iOS and macOS targets — `supportedDestinations:
  [iOS, macOS]`. Simpler, and it is the modern Xcode default.
- **`TimeWindow`, not `DateInterval`.** The engine originally defined `DateInterval`, which
  shadows Foundation's type and made every file importing both ambiguous. Renamed.
- **`SwiftData` stores the request and plan as encoded blobs**, not as a mirrored object
  graph. The engine's types are already `Codable`, and mirroring them would create a second
  definition of a plan that could silently drift from the first.
- **The plan covers the return leg.** The day timeline runs to the homebound arrival plus a
  few days, and the target phase flips back to home time once the return flight departs, so
  re-adaptation is planned rather than left to the reader.
- **Partial shifts aim at `rate × stayDays / 2`**, i.e. as far as you can comfortably get in
  half the stay. That specific formula is a judgement call, not a published rule.
- **Sleep is filed under the day its bedtime falls on.** This is the convention the whole
  engine uses, and it is the source of three bugs found and fixed during development (the
  nap, the caffeine window and the anchor-light window all initially landed a day early).
- **`-demoScreen <name>`** is a `#if DEBUG` launch argument that boots straight into one
  screen with seeded data, so every README screenshot is generated by
  `tools/screenshots.sh` rather than assembled by hand. Compiled out of release builds.
- **Code-signing identity lives in an untracked `Local.xcconfig`**, included optionally by
  a tracked `Signing.xcconfig`. A clone without it still builds for the simulator and the
  Mac; it just cannot sign for a device until you add your own team.
