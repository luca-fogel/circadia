import SwiftUI
import CircadianKit

/// A single day compressed into a twenty-four-hour horizontal bar.
///
/// The wheel is for reading one day closely; the ribbon is for scanning the whole trip and
/// seeing the shape of the shift — the sleep block walking steadily across the strip is the
/// clearest picture of what the plan is actually doing to you.
struct DayRibbon: View {
    let day: DayPlan
    let isSelected: Bool
    var showsHourScale = false
    /// Events from neighbouring days that spill into this one — chiefly the tail of last
    /// night's sleep, which belongs to yesterday's `DayPlan` but happened this morning.
    var carriedOver: [PlanEvent] = []

    private var zone: TimeZone { day.timeZone }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Format.weekday(day.localDayStart.addingTimeInterval(3600), in: zone))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                Text(day.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if abs(day.achievedShiftHours) > 0.05 {
                    Text(Format.shift(day.achievedShiftHours))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.directionTint(
                            ShiftDirection(signedShift: day.achievedShiftHours, threshold: 0.05)
                        ))
                }
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    dayNightBackground(width: width)
                    ForEach(bars, id: \.id) { bar in
                        Capsule(style: .continuous)
                            .fill(bar.colour)
                            .frame(width: max(2, bar.width * width), height: bar.height)
                            .offset(x: bar.start * width, y: bar.offsetY)
                    }
                    temperatureMinimumTick(width: width)
                }
            }
            .frame(height: Theme.ribbonHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }

            if showsHourScale {
                HStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, to: 24, by: 6)), id: \.self) { hour in
                        Text("\(hour):00")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Layers

    @ViewBuilder
    private func dayNightBackground(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.nightFill)
            if day.isPolarDay {
                Rectangle().fill(Theme.dayFill)
            } else if let sunrise = day.sunrise, let sunset = day.sunset, !day.isPolarNight {
                let start = fraction(of: sunrise)
                let end = fraction(of: sunset)
                if end > start {
                    Rectangle()
                        .fill(Theme.daylight)
                        .frame(width: (end - start) * width)
                        .offset(x: start * width)
                }
            }
        }
    }

    private func temperatureMinimumTick(width: CGFloat) -> some View {
        let x = fraction(of: day.cbtMinAtStart)
        return Rectangle()
            .fill(Color(red: 0.95, green: 0.35, blue: 0.45))
            .frame(width: 1.5, height: Theme.ribbonHeight)
            .offset(x: x * width)
            .opacity(x >= 0 && x <= 1 ? 1 : 0)
    }

    // MARK: - Bar layout

    private struct Bar: Identifiable {
        let id = UUID()
        let start: CGFloat
        let width: CGFloat
        let height: CGFloat
        let offsetY: CGFloat
        let colour: Color
    }

    /// Two lanes: sleep on the lower half, light guidance on the upper half.
    /// Which lane an event occupies, or `nil` for events the ribbon does not draw.
    private func style(for kind: PlanEvent.Kind) -> (height: CGFloat, offsetY: CGFloat, colour: Color)? {
        switch kind {
        case .sleep: (12, 12, Theme.sleep)
        case .nap: (12, 12, Theme.nap)
        case .seekLight: (12, -6, Theme.seekLight)
        case .seekArtificialLight: (12, -6, Theme.artificialLight)
        case .avoidLight: (12, -6, Theme.avoidLight)
        case .mitigateLight: (12, -6, Theme.mitigate)
        case .melatonin: (8, 12, Theme.melatonin)
        default: nil
        }
    }

    private var bars: [Bar] {
        (day.events + carriedOver).compactMap { event in
            guard let (height, offsetY, colour) = style(for: event.kind) else { return nil }

            let start = fraction(of: event.interval.start)
            let end = fraction(of: event.interval.end)
            let clampedStart = max(0, start)
            let clampedEnd = min(1, end)
            guard clampedEnd > clampedStart else { return nil }

            return Bar(
                start: clampedStart,
                width: clampedEnd - clampedStart,
                height: height,
                offsetY: offsetY,
                colour: colour
            )
        }
    }

    /// Position within the day as `0...1`.
    private func fraction(of date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(day.localDayStart) / 86400)
    }
}
