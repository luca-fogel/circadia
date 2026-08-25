import SwiftUI
import SwiftData
import CircadianKit

/// The plan.
///
/// Three levels of zoom, top to bottom: what the plan is trying to do and why, the shape of
/// the whole trip as a stack of ribbons, and then one day in detail on the wheel with its
/// instructions listed underneath.
struct PlanTimelineView: View {
    let trip: StoredTrip

    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.modelContext) private var context

    @State private var selectedDayIndex: Int?
    @State private var showingScience = false

    private var plan: CircadianPlan? { trip.plan }

    var body: some View {
        ScrollView {
            if let plan {
                VStack(alignment: .leading, spacing: 24) {
                    StrategyCard(plan: plan)
                    tripOverview(plan)
                    selectedDaySection(plan)
                    notificationSection(plan)
                    DisclaimerFooter()
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "Plan unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This trip's plan could not be read. Regenerating it usually fixes it.")
                )
                .padding()
            }
        }
        .navigationTitle(trip.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        trip.regeneratePlan()
                        try? context.save()
                        if let plan = trip.plan {
                            Task { await scheduler.reschedule(for: plan, tripID: trip.id) }
                        }
                    } label: {
                        Label("Rebuild plan", systemImage: "arrow.clockwise")
                    }
                    Button { showingScience = true } label: {
                        Label("How this works", systemImage: "book")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingScience) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let plan { PRCChartView(plan: plan) }
                        AboutTheScience()
                        DisclaimerPanel()
                    }
                    .padding()
                }
                .navigationTitle("How this works")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingScience = false }
                    }
                }
            }
        }
        .onAppear {
            if selectedDayIndex == nil {
                selectedDayIndex = trip.currentDay()?.dayIndex ?? plan?.days.first?.dayIndex
            }
        }
    }

    // MARK: - Sections

    private func tripOverview(_ plan: CircadianPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("The whole trip", subtitle: "Tap a day to open it")
            VStack(spacing: 10) {
                ForEach(Array(plan.days.enumerated()), id: \.element.dayIndex) { index, day in
                    Button {
                        withAnimation(.snappy) { selectedDayIndex = day.dayIndex }
                    } label: {
                        DayRibbon(
                            day: day,
                            isSelected: day.dayIndex == selectedDayIndex,
                            showsHourScale: index == plan.days.count - 1,
                            carriedOver: Self.spillOver(into: day, from: plan)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            WheelLegend(events: plan.events)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func selectedDaySection(_ plan: CircadianPlan) -> some View {
        if let day = plan.days.first(where: { $0.dayIndex == selectedDayIndex }) ?? plan.days.first {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    day.title,
                    subtitle: "\(Format.weekday(day.localDayStart.addingTimeInterval(3600), in: day.timeZone)) · \(day.place.displayName)"
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        CircadianWheel(day: day, now: .now, carriedOver: Self.spillOver(into: day, from: plan))
                            .frame(width: 260)
                        dayDetails(day)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        CircadianWheel(day: day, now: .now, carriedOver: Self.spillOver(into: day, from: plan))
                            .frame(maxWidth: 320)
                            .frame(maxWidth: .infinity)
                        dayDetails(day)
                    }
                }
            }
        }
    }

    private func dayDetails(_ day: DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !day.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(day.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.bottom, 4)
            }

            SunSummary(day: day)
                .padding(.bottom, 4)

            ForEach(day.events.filter { $0.kind != .caffeineAvoid }) { event in
                EventRow(event: event)
                if event.id != day.events.filter({ $0.kind != .caffeineAvoid }).last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func notificationSection(_ plan: CircadianPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Reminders", subtitle: nil)
            switch scheduler.authorisation {
            case .granted, .provisional:
                Label(
                    scheduler.scheduledCount > 0
                        ? "\(scheduler.scheduledCount) reminders scheduled"
                        : "Reminders on",
                    systemImage: "bell.badge.fill"
                )
                .font(.subheadline)
                if plan.upcomingEvents().count > NotificationScheduler.budget {
                    Text("This plan has \(plan.upcomingEvents().count) upcoming events but iOS allows only \(NotificationScheduler.budget) pending reminders, so the light and sleep windows are notified first and the caffeine reminders are dropped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Reminders are off", systemImage: "bell.slash")
                        .font(.subheadline)
                    Text("Turn notifications on for Circadia in Settings to be nudged at the start of each window.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .unknown:
                Button {
                    Task {
                        await scheduler.requestAuthorisation()
                        await scheduler.reschedule(for: plan, tripID: trip.id)
                    }
                } label: {
                    Label("Turn on reminders", systemImage: "bell")
                }
                .buttonStyle(.bordered)
            }
        }
        .task { await scheduler.refreshAuthorisation() }
    }
}

extension PlanTimelineView {
    /// Events belonging to the previous day that overlap `day`.
    ///
    /// A night is filed under the day its bedtime falls on, so without this the hours
    /// between midnight and waking render empty on every ribbon and dial.
    static func spillOver(into day: DayPlan, from plan: CircadianPlan) -> [PlanEvent] {
        guard let previous = plan.days.first(where: { $0.dayIndex == day.dayIndex - 1 }) else { return [] }
        let window = TimeWindow(
            start: day.localDayStart,
            end: day.localDayStart.addingTimeInterval(24 * 3600)
        )
        return previous.events.filter { $0.interval.intersects(window) }
    }
}

// MARK: - Cards

struct StrategyCard: View {
    let plan: CircadianPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.directionTint(plan.strategy.direction))
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.strategy.kind.displayName)
                        .font(.headline)
                    Text(plan.strategy.direction.travelDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(plan.strategy.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                ForEach(stats, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if plan.compromisedEventCount > 0 {
                Label(
                    "\(plan.compromisedEventCount) windows had to be compromised for your commitments.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var symbol: String {
        switch plan.strategy.kind {
        case .noShiftNeeded: "checkmark.circle.fill"
        case .stayOnHomeTime: "house.fill"
        case .partialShift: "arrow.left.and.right.circle.fill"
        case .fullShift: plan.strategy.direction == .advance ? "arrow.left.circle.fill" : "arrow.right.circle.fill"
        }
    }

    private var stats: [(String, String)] {
        var result: [(String, String)] = [
            ("clock change", String(format: "%+.0f h", plan.request.outbound.rawZoneDifferenceHours))
        ]
        if plan.strategy.kind != .noShiftNeeded && plan.strategy.kind != .stayOnHomeTime {
            result.append(("shift planned", Format.shift(plan.strategy.targetShiftHours)))
        }
        if let day = plan.dayAdaptationReached {
            result.append(("adapted by", day <= 0 ? "before you fly" : "day \(day)"))
        } else if plan.strategy.kind == .fullShift {
            result.append(("adapted by", "not within plan"))
        }
        if abs(plan.residualMisalignmentHours) > 0.25 {
            result.append(("left over", Format.hours(abs(plan.residualMisalignmentHours))))
        }
        return result
    }
}

struct SunSummary: View {
    let day: DayPlan

    var body: some View {
        HStack(spacing: 14) {
            if day.isPolarDay {
                Label("Sun never sets", systemImage: "sun.max.fill")
            } else if day.isPolarNight {
                Label("Sun never rises", systemImage: "moon.stars.fill")
            } else {
                if let sunrise = day.sunrise {
                    Label(Format.time(sunrise, in: day.timeZone), systemImage: "sunrise")
                }
                if let sunset = day.sunset {
                    Label(Format.time(sunset, in: day.timeZone), systemImage: "sunset")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
