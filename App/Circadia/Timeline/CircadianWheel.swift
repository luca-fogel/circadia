import SwiftUI
import CircadianKit

/// A twenty-four-hour dial for one day of the plan.
///
/// A circadian day *is* a cycle, so a ring shows it more truthfully than a bar: the
/// relationship between your temperature minimum, the night and the light windows is an
/// angular one, and on a ring you can see the whole thing at once without the seam that a
/// linear timeline puts through the middle of the night.
///
/// Midnight sits at the top and the day runs clockwise, matching a clock face.
struct CircadianWheel: View {
    let day: DayPlan
    /// Drawn as a hand if the day is today.
    let now: Date?
    /// Events from neighbouring days that spill into this one, so the small hours are not
    /// left blank while last night's sleep sits in yesterday's `DayPlan`.
    var carriedOver: [PlanEvent] = []

    private var zone: TimeZone { day.timeZone }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(size.width, size.height) / 2 - 18

            drawNightAndDay(context: context, centre: centre, radius: outer)
            drawTicks(context: context, centre: centre, radius: outer)
            drawEventRings(context: context, centre: centre, radius: outer)
            drawTemperatureMinimum(context: context, centre: centre, radius: outer)
            if let now, isToday(now) {
                drawNowHand(context: context, centre: centre, radius: outer, now: now)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay { centreLabel }
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Geometry

    /// Fractional hours since the day's local midnight.
    private func hour(of date: Date) -> Double {
        date.timeIntervalSince(day.localDayStart) / 3600
    }

    /// Midnight at the top, clockwise. Canvas angles run clockwise from the positive x
    /// axis, so a quarter turn is subtracted to put hour zero at twelve o'clock.
    private func angle(atHour hour: Double) -> Angle {
        .degrees(hour / 24 * 360 - 90)
    }

    /// Clips an interval to this local day, returning hour ranges inside `0...24`.
    private func spans(_ interval: TimeWindow) -> [(Double, Double)] {
        let start = hour(of: interval.start)
        let end = hour(of: interval.end)
        guard end > 0, start < 24 else { return [] }
        return [(max(0, start), min(24, end))].filter { $0.1 - $0.0 > 0.01 }
    }

    private func arc(centre: CGPoint, radius: CGFloat, thickness: CGFloat, from: Double, to: Double) -> Path {
        var path = Path()
        path.addArc(
            center: centre,
            radius: radius - thickness / 2,
            startAngle: angle(atHour: from),
            endAngle: angle(atHour: to),
            clockwise: false
        )
        return path.strokedPath(.init(lineWidth: thickness, lineCap: .butt))
    }

    // MARK: - Layers

    private func drawNightAndDay(context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let thickness: CGFloat = 22

        // Night is the default state of the ring; daylight is painted over it.
        context.fill(
            arc(centre: centre, radius: radius, thickness: thickness, from: 0, to: 24),
            with: .color(Theme.nightFill)
        )

        if day.isPolarDay {
            context.fill(
                arc(centre: centre, radius: radius, thickness: thickness, from: 0, to: 24),
                with: .color(Theme.dayFill)
            )
        } else if !day.isPolarNight, let sunrise = day.sunrise, let sunset = day.sunset {
            for (from, to) in spans(TimeWindow(start: sunrise, end: sunset)) {
                context.fill(
                    arc(centre: centre, radius: radius, thickness: thickness, from: from, to: to),
                    with: .color(Theme.dayFill)
                )
            }
        }
    }

    private func drawTicks(context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        for tick in stride(from: 0, to: 24, by: 3) {
            let a = angle(atHour: Double(tick)).radians
            let inner = radius - 26
            let outerPoint = CGPoint(x: centre.x + cos(a) * (radius + 2), y: centre.y + sin(a) * (radius + 2))
            let innerPoint = CGPoint(x: centre.x + cos(a) * inner, y: centre.y + sin(a) * inner)

            var line = Path()
            line.move(to: innerPoint)
            line.addLine(to: outerPoint)
            context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 1)

            let labelPoint = CGPoint(x: centre.x + cos(a) * (radius + 12), y: centre.y + sin(a) * (radius + 12))
            context.draw(
                Text("\(tick)").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary),
                at: labelPoint
            )
        }
    }

    /// Sleep on one ring, light guidance on the next, so the two never obscure each other.
    private func drawEventRings(context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let sleepRadius = radius - 24
        let lightRadius = radius - 42

        /// Which ring an event belongs on, or `nil` for events the dial does not draw.
        func style(for kind: PlanEvent.Kind) -> (radius: CGFloat, thickness: CGFloat, colour: Color)? {
            switch kind {
            case .sleep: (sleepRadius, 14, Theme.sleep)
            case .nap: (sleepRadius, 14, Theme.nap)
            case .seekLight: (lightRadius, 16, Theme.seekLight)
            case .seekArtificialLight: (lightRadius, 16, Theme.artificialLight)
            case .avoidLight: (lightRadius, 16, Theme.avoidLight)
            case .mitigateLight: (lightRadius, 16, Theme.mitigate)
            default: nil
            }
        }

        for event in day.events + carriedOver {
            guard let (ringRadius, thickness, colour) = style(for: event.kind) else { continue }

            for (from, to) in spans(event.interval) {
                context.fill(
                    arc(centre: centre, radius: ringRadius, thickness: thickness, from: from, to: to),
                    with: .color(colour.opacity(event.kind == .avoidLight ? 0.9 : 0.95))
                )
            }
        }

        // Point events sit as dots on the light ring so they are not lost.
        for event in (day.events + carriedOver) where event.kind == .melatonin {
            for (from, _) in spans(event.interval) {
                let a = angle(atHour: from).radians
                let r = lightRadius - 8
                let point = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                    with: .color(Theme.melatonin)
                )
            }
        }
    }

    /// The pivot everything else is measured from.
    private func drawTemperatureMinimum(context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let h = hour(of: day.cbtMinAtStart)
        guard h >= 0, h <= 24 else { return }
        let a = angle(atHour: h).radians

        var marker = Path()
        marker.move(to: CGPoint(x: centre.x + cos(a) * (radius - 52), y: centre.y + sin(a) * (radius - 52)))
        marker.addLine(to: CGPoint(x: centre.x + cos(a) * (radius - 8), y: centre.y + sin(a) * (radius - 8)))
        context.stroke(marker, with: .color(Color(red: 0.85, green: 0.24, blue: 0.35)), lineWidth: 2)

        let dot = CGPoint(x: centre.x + cos(a) * (radius - 52), y: centre.y + sin(a) * (radius - 52))
        context.fill(
            Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)),
            with: .color(Color(red: 0.85, green: 0.24, blue: 0.35))
        )
    }

    private func drawNowHand(context: GraphicsContext, centre: CGPoint, radius: CGFloat, now: Date) {
        let a = angle(atHour: hour(of: now)).radians
        var hand = Path()
        hand.move(to: centre)
        hand.addLine(to: CGPoint(x: centre.x + cos(a) * (radius - 4), y: centre.y + sin(a) * (radius - 4)))
        context.stroke(hand, with: .color(.primary.opacity(0.55)), lineWidth: 1.5)
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)),
            with: .color(.primary.opacity(0.55))
        )
    }

    private func isToday(_ now: Date) -> Bool {
        now >= day.localDayStart && now < day.localDayStart.addingTimeInterval(24 * 3600)
    }

    // MARK: - Centre

    private var centreLabel: some View {
        VStack(spacing: 2) {
            Text(day.place.city)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Format.weekday(day.localDayStart.addingTimeInterval(3600), in: zone))
                .font(.headline)
            if abs(day.achievedShiftHours) > 0.05 {
                Text(Format.shift(day.achievedShiftHours))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.directionTint(
                        ShiftDirection(signedShift: day.achievedShiftHours, threshold: 0.05)
                    ))
            } else {
                Text("holding")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
    }

    private var accessibilitySummary: String {
        var parts = ["\(Format.weekday(day.localDayStart, in: zone)) in \(day.place.city)"]
        if let sunrise = day.sunrise, let sunset = day.sunset {
            parts.append("daylight from \(Format.time(sunrise, in: zone)) to \(Format.time(sunset, in: zone))")
        }
        for event in day.events where event.kind != .caffeineAvoid {
            parts.append("\(event.title), \(Format.range(event.interval, in: zone))")
        }
        return parts.joined(separator: ". ")
    }
}

/// Key for the wheel, so the colours mean something without having to guess.
///
/// Keys only what is actually drawn: a legend entry for a window the plan did not
/// prescribe sends the reader hunting the dial for a colour that is not there.
struct WheelLegend: View {
    /// Events on display. Pass `nil` to key everything.
    var events: [PlanEvent]?

    private var items: [(String, Color)] {
        let all: [(String, Color, PlanEvent.Kind?)] = [
            ("Bright light", Theme.seekLight, .seekLight),
            ("Bright light indoors", Theme.artificialLight, .seekArtificialLight),
            ("Avoid light", Theme.avoidLight, .avoidLight),
            ("Sleep", Theme.sleep, .sleep),
            ("Nap", Theme.nap, .nap),
            ("Melatonin", Theme.melatonin, .melatonin),
            ("Temp. minimum", Color(red: 0.85, green: 0.24, blue: 0.35), nil)
        ]
        guard let events else { return all.map { ($0.0, $0.1) } }
        let present = Set(events.map(\.kind))
        return all
            .filter { $0.2 == nil || present.contains($0.2!) }
            .map { ($0.0, $0.1) }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var chips: some View {
        ForEach(items, id: \.0) { label, colour in
            HStack(spacing: 4) {
                Circle().fill(colour).frame(width: 7, height: 7)
                Text(label)
            }
        }
    }
}
