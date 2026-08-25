import SwiftUI
import CircadianKit

/// The phase-response curve itself, with the plan's own windows marked on it.
///
/// This is the answer to "why is it telling me to go outside at 07:30?" — you can see the
/// window sitting on the peak of the advance lobe, and see how much of the curve you lose
/// by moving it.
struct PRCChartView: View {
    let plan: CircadianPlan

    private let curve = DualHarmonicPRC.khalsa2003Light

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The light phase-response curve")
                .font(.headline)

            Text("How far a bright-light pulse moves your clock, depending on when you get it. Zero on this axis is your body's temperature minimum — light after it pulls you earlier, light before it pushes you later.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 16)
                draw(context: context, in: rect)
            }
            .frame(height: 190)

            HStack(spacing: 16) {
                legend(colour: Theme.seekLight, label: "advance")
                legend(colour: Theme.sleep, label: "delay")
                HStack(spacing: 4) {
                    Circle().fill(.primary.opacity(0.65)).frame(width: 6, height: 6)
                    Text("where this plan puts your light")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(curve.citation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func legend(colour: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(colour).frame(width: 12, height: 3)
            Text(label)
        }
    }

    // MARK: - Drawing

    /// The curve is plotted over `-12...12` hours relative to the temperature minimum,
    /// which puts the crossover in the middle where it belongs.
    private func draw(context: GraphicsContext, in rect: CGRect) {
        let maxAmplitude = 3.0

        func x(_ hours: Double) -> CGFloat {
            rect.minX + CGFloat((hours + 12) / 24) * rect.width
        }
        func y(_ shift: Double) -> CGFloat {
            rect.midY - CGFloat(shift / maxAmplitude) * (rect.height / 2)
        }

        // Horizontal gridlines, labelled, so the vertical axis has units.
        for shift in [-2.0, 0.0, 2.0] {
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y(shift)))
            line.addLine(to: CGPoint(x: rect.maxX, y: y(shift)))
            context.stroke(
                line,
                with: .color(.primary.opacity(shift == 0 ? 0.18 : 0.07)),
                lineWidth: 1
            )
            let label = shift == 0 ? "0" : String(format: "%+.0fh", shift)
            context.draw(
                Text(label).font(.system(size: 8)).foregroundStyle(.tertiary),
                at: CGPoint(x: rect.minX - 11, y: y(shift))
            )
        }

        var axis = Path()
        axis.move(to: CGPoint(x: x(0), y: rect.minY))
        axis.addLine(to: CGPoint(x: x(0), y: rect.maxY))
        context.stroke(
            axis,
            with: .color(Color(red: 0.85, green: 0.24, blue: 0.35).opacity(0.7)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        context.draw(
            Text("temp. min").font(.system(size: 8)).foregroundStyle(.secondary),
            at: CGPoint(x: x(0), y: rect.minY - 4)
        )

        // The curve, split at the zero crossing so each lobe gets its own colour.
        var advance = Path()
        var delay = Path()
        var startedAdvance = false
        var startedDelay = false

        for step in 0...480 {
            let hours = -12 + Double(step) / 480 * 24
            let value = curve.shift(atPhase: hours)
            let point = CGPoint(x: x(hours), y: y(value))
            if value >= 0 {
                if startedAdvance { advance.addLine(to: point) } else { advance.move(to: point); startedAdvance = true }
                startedDelay = false
            } else {
                if startedDelay { delay.addLine(to: point) } else { delay.move(to: point); startedDelay = true }
                startedAdvance = false
            }
        }
        context.stroke(advance, with: .color(Theme.seekLight), lineWidth: 2.5)
        context.stroke(delay, with: .color(Theme.sleep), lineWidth: 2.5)

        // Hour labels.
        for hours in stride(from: -12.0, through: 12.0, by: 6) {
            context.draw(
                Text("\(Int(hours))h").font(.system(size: 8)).foregroundStyle(.tertiary),
                at: CGPoint(x: x(hours), y: rect.maxY + 8)
            )
        }

        // Where the plan actually put its light windows.
        for phase in windowPhases {
            let value = curve.shift(atPhase: phase)
            let point = CGPoint(x: x(CircadianHours.signedOffset(phase)), y: y(value))
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)),
                with: .color(.primary.opacity(0.65))
            )
        }
    }

    /// Circadian phase of the midpoint of each prescribed light window.
    private var windowPhases: [Double] {
        plan.days.flatMap { day -> [Double] in
            let state = CircadianState(cbtMin: day.cbtMinAtStart)
            return day.events
                .filter { $0.kind == .seekLight || $0.kind == .seekArtificialLight }
                .filter { $0.predictedShiftHours != nil }
                .map { state.phase(of: $0.interval.midpoint) }
        }
    }
}
