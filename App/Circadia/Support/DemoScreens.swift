#if DEBUG
import SwiftUI
import SwiftData
import CircadianKit

/// One screen of the app, with deterministic seeded data, selected by a launch argument.
///
/// This exists so every screenshot in the README can be regenerated from a clean
/// simulator by `tools/screenshots.sh`. Nothing is mocked: the plans below are produced by
/// the real engine from real itineraries, and the views are the shipping views.
///
/// Compiled out of release builds.
enum DemoScreen: String, CaseIterable {
    case trips
    case plan
    case day
    case science
    case onboarding

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> DemoScreen? {
        guard let index = arguments.firstIndex(of: "-demoScreen"),
              arguments.index(after: index) < arguments.endIndex,
              let screen = DemoScreen(rawValue: arguments[arguments.index(after: index)])
        else { return nil }
        return screen
    }
}

struct DemoScreenHost: View {
    let screen: DemoScreen

    @Environment(\.modelContext) private var context
    @State private var trips: [StoredTrip] = []

    var body: some View {
        Group {
            switch screen {
            case .onboarding:
                OnboardingFlow()
            case .trips:
                TripListView()
            case .plan:
                NavigationStack {
                    if let trip = trips.first { PlanTimelineView(trip: trip) } else { ProgressView() }
                }
            case .day:
                NavigationStack {
                    if let plan = trips.first?.plan, let day = DemoTrips.focusDay(of: plan) {
                        DayFocusScreen(plan: plan, day: day)
                    } else { ProgressView() }
                }
            case .science:
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if let plan = trips.first?.plan { PRCChartView(plan: plan) }
                            AboutTheScience()
                            DisclaimerPanel()
                        }
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .navigationTitle("How this works")
                }
            }
        }
        .task {
            guard trips.isEmpty else { return }
            trips = DemoTrips.seed(into: context)
        }
    }
}

/// A standalone screen for the dial, so the README can show it at a readable size.
private struct DayFocusScreen: View {
    let plan: CircadianPlan
    let day: DayPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    day.title,
                    subtitle: "\(Format.weekday(day.localDayStart.addingTimeInterval(3600), in: day.timeZone)) · \(day.place.displayName)"
                )
                CircadianWheel(
                    day: day,
                    now: nil,
                    carriedOver: PlanTimelineView.spillOver(into: day, from: plan)
                )
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)

                WheelLegend(events: day.events + PlanTimelineView.spillOver(into: day, from: plan))
                SunSummary(day: day)
                Divider()

                ForEach(day.events.filter { $0.kind != .caffeineAvoid }) { event in
                    EventRow(event: event)
                    Divider()
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Your day")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The itineraries the screenshots are built from. Chosen to show three different
/// strategies, because the strategy choice is the most interesting thing the engine does.
enum DemoTrips {

    @MainActor
    static func seed(into context: ModelContext) -> [StoredTrip] {
        // Demo mode owns the store. The screenshot script launches the app once per
        // screen, and without this each launch would stack another copy of every trip.
        if let existing = try? context.fetch(FetchDescriptor<StoredTrip>()) {
            for trip in existing { context.delete(trip) }
        }
        let stored = itineraries().map { request -> StoredTrip in
            let plan = CircadianPlanner().makePlan(for: request)
            let trip = StoredTrip(request: request, plan: plan)
            context.insert(trip)
            return trip
        }
        try? context.save()
        return stored
    }

    static func itineraries() -> [TripPlanRequest] {
        [heathrowToTokyo(), newYorkToTokyo(), londonToLosAngelesOvernight()].compactMap { $0 }
    }

    private static func place(_ iata: String) -> Place? {
        PlaceDatabase.shared.place(iata: iata)
    }

    private static func instant(_ place: Place, _ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date? {
        place.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))
    }

    /// An 8 h advance with a real constraint, so the practicality filter shows its work.
    private static func heathrowToTokyo() -> TripPlanRequest? {
        guard let origin = place("LHR"), let destination = place("NRT"),
              let departure = instant(origin, 2026, 9, 10, 13) else { return nil }
        return TripPlanRequest(
            outbound: Flight(
                origin: origin, destination: destination,
                departure: departure, arrival: departure.addingTimeInterval(12 * 3600)
            ),
            sleeper: Sleeper(chronotype: .intermediate, habitualBedtime: ClockTime(hour: 23),
                             habitualWake: ClockTime(hour: 7), age: 30),
            constraints: [
                PracticalityConstraint(
                    kind: .brightLightUnavailable,
                    from: ClockTime(hour: 9), to: ClockTime(hour: 13),
                    label: "conference sessions"
                )
            ]
        )
    }

    /// Thirteen hours east, planned as an eleven-hour delay.
    private static func newYorkToTokyo() -> TripPlanRequest? {
        guard let origin = place("JFK"), let destination = place("NRT"),
              let departure = instant(origin, 2026, 10, 2, 11) else { return nil }
        return TripPlanRequest(
            outbound: Flight(
                origin: origin, destination: destination,
                departure: departure, arrival: departure.addingTimeInterval(14 * 3600)
            ),
            sleeper: Sleeper(chronotype: .moderateEvening, habitualBedtime: ClockTime(hour: 0),
                             habitualWake: ClockTime(hour: 8), age: 27)
        )
    }

    /// Two nights across eight zones: the quick-turnaround case, where not shifting wins.
    private static func londonToLosAngelesOvernight() -> TripPlanRequest? {
        guard let origin = place("LHR"), let destination = place("LAX"),
              let out = instant(origin, 2026, 11, 5, 11),
              let back = instant(destination, 2026, 11, 7, 16) else { return nil }
        return TripPlanRequest(
            outbound: Flight(origin: origin, destination: destination,
                             departure: out, arrival: out.addingTimeInterval(11 * 3600)),
            homebound: Flight(origin: destination, destination: origin,
                              departure: back, arrival: back.addingTimeInterval(10 * 3600)),
            sleeper: Sleeper(chronotype: .moderateMorning, habitualBedtime: ClockTime(hour: 22, minute: 30),
                             habitualWake: ClockTime(hour: 6, minute: 30), age: 41)
        )
    }

    /// The day worth showing on the dial: the first full day after arrival.
    static func focusDay(of plan: CircadianPlan) -> DayPlan? {
        plan.days.first { $0.dayIndex == 2 } ?? plan.days.last
    }
}
#endif
