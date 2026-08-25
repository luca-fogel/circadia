# Contributing

This is a personal project, but the engine — `Packages/CircadianKit` — is the part
that is generally useful, the part most likely to have a bug you have hit too, and
the part you can work on without Xcode. Those are the contributions I most want.

## Start here

```sh
swift test --package-path Packages/CircadianKit   # ~0.1s, no Xcode, no simulator
tools/check.sh                                    # what CI runs
open Circadia.xcodeproj                           # then ⌘R
```

For a screenshot or a quick look at one screen without walking the questionnaire,
debug builds take `-demoScreen plan|day|trips|science|onboarding`.

## The rules this code lives by

- **A number in the engine either has a citation or is flagged as a guess.** Every
  published value is cited in a doc comment at the point of use. The one
  quantitative relationship with no specific source behind it —
  `Sleeper.lightSensitivity` — says so in its own comment and in
  [DEVIATIONS.md](DEVIATIONS.md). Please keep that property: if you add a constant,
  either say where it came from or say that you made it up.
- **The engine imports Foundation and nothing else.** No SwiftUI, no UIKit, no
  SwiftData. This is what lets the whole model be tested in a tenth of a second
  with no simulator, and `tools/check.sh` fails if it stops being true.
- **The advice has to be followable.** A light window that overlaps the sleep block
  is not advice, it is noise — you cannot get light with your eyes shut. Windows
  are clipped out of sleep and out of the dark for the same reason. If you add a
  prescription, ask when a real person would actually be able to act on it.
- **A constraint is never silently ignored, and never silently free.** When the
  practicality filter moves a window it records which constraint moved it and what
  fraction of the ideal effect survived. When light cannot be avoided, the residual
  wrong-way shift is *subtracted from that day's progress*. Do not add a path that
  drops a constraint without accounting for it.
- **The plan explains itself.** Every strategy carries a prose rationale, and every
  event carries a `detail` string that doubles as the notification body. An event
  the user cannot understand the reason for is a bug.
- **Prefer changing the model to changing the output.** If a plan looks wrong,
  find the physiology or the arithmetic that produced it. Three of the bugs in this
  repository's history were found exactly that way, by writing down what the
  literature says and then discovering the code disagreed.
- **Time zones are IANA identifiers resolved at an instant, never fixed offsets.**
  A trip that crosses a daylight-saving transition has a test. Keep it passing.

## Tests

Anything that can be tested without a simulator belongs in
`Packages/CircadianKit/Tests` with a test. The scenario tests are written as
itineraries rather than as date arithmetic — see `TripFixtures.swift` — so a new
case usually costs three lines.

Tests that assert what a *paper* says, rather than what the code currently does,
are the valuable ones. `PhaseResponseCurveTests` is written that way on purpose:
it checks the fitted curve against Khalsa's published extrema, zero crossings and
explicit statement that there is no dead zone. One of those tests caught my own
expectation being wrong rather than the code.

## Sign your work (DCO)

Add a `Signed-off-by` line to each commit — `git commit -s` does it for you:

```
Signed-off-by: Your Name <your.email@example.com>
```

That line is the [Developer Certificate of Origin](https://developercertificate.org/):
you are stating that you wrote the patch, or otherwise have the right to submit it
under this project's licence (GPL-3.0). It is one line, not a copyright
assignment — you keep the copyright in your own work.

## What this project will not become

It will not gain accounts, a backend, telemetry, or a subscription. It will not
start claiming clinical validity it does not have. And it will not reproduce
anyone's proprietary algorithm — the point is what can be built from the published
literature, which is a more interesting question anyway.
