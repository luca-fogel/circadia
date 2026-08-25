import SwiftUI
import CircadianKit

/// One instruction, as a row.
struct EventRow: View {
    let event: PlanEvent
    @State private var isExpanded = false

    private var zone: TimeZone { event.displayTimeZone }
    private var colour: Color { Theme.color(for: event.kind) }

    var body: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(colour.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: event.kind.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colour)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if event.isCompromised {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if isExpanded {
                        Text(event.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)

                        if !metrics.isEmpty {
                            HStack(spacing: 12) {
                                ForEach(metrics, id: \.0) { label, value in
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(value).font(.caption.weight(.medium).monospacedDigit())
                                        Text(label).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        Text(event.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var timeLabel: String {
        // Point-in-time events read better as a single time than as a one-minute range.
        if event.interval.durationHours <= 0.3 {
            return Format.time(event.interval.start, in: zone)
        }
        return Format.range(event.interval, in: zone)
    }

    /// The numbers behind the advice, shown on expansion rather than cluttering the row.
    private var metrics: [(String, String)] {
        var result: [(String, String)] = []
        if let shift = event.predictedShiftHours, abs(shift) > 0.01 {
            result.append(("predicted shift", Format.shift(shift)))
        }
        if let lux = event.assumedLux, lux > 10 {
            result.append(("assumes", "\(Int(lux.rounded())) lux"))
        }
        if event.efficacy < 0.999 {
            result.append(("of ideal effect", "\(Int((event.efficacy * 100).rounded()))%"))
        }
        if let constraint = event.adjustedForConstraint {
            result.append(("moved for", constraint))
        }
        return result
    }
}
