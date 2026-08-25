import SwiftUI
import SwiftData
import CircadianKit

/// Root screen: your trips.
struct TripListView: View {
    @Environment(\.modelContext) private var context
    @Environment(NotificationScheduler.self) private var scheduler

    @Query(sort: \StoredTrip.departure, order: .reverse)
    private var trips: [StoredTrip]

    @State private var isCreating = false

    private var upcoming: [StoredTrip] { trips.filter { !$0.isPast }.sorted { $0.departure < $1.departure } }
    private var past: [StoredTrip] { trips.filter(\.isPast) }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Circadia")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New trip", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreating) {
                OnboardingFlow()
            }
            .task { await scheduler.refreshAuthorisation() }
        }
    }

    private var list: some View {
        List {
            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming) { trip in
                        NavigationLink { PlanTimelineView(trip: trip) } label: { TripRow(trip: trip) }
                    }
                    .onDelete { delete($0, from: upcoming) }
                }
            }
            if !past.isEmpty {
                Section("Past") {
                    ForEach(past) { trip in
                        NavigationLink { PlanTimelineView(trip: trip) } label: { TripRow(trip: trip) }
                    }
                    .onDelete { delete($0, from: past) }
                }
            }
            Section {
                DisclaimerFooter()
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "circle.hexagongrid.circle")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Text("No trips yet")
                        .font(.title2.weight(.semibold))
                    Text("Add a flight and Circadia will build an hour-by-hour light, sleep and melatonin plan from the published circadian research.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    isCreating = true
                } label: {
                    Label("Plan a trip", systemImage: "airplane.departure")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                DisclaimerPanel()
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private func delete(_ offsets: IndexSet, from source: [StoredTrip]) {
        for index in offsets {
            let trip = source[index]
            scheduler.cancel(tripID: trip.id)
            context.delete(trip)
        }
        try? context.save()
    }
}

private struct TripRow: View {
    let trip: StoredTrip

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(trip.originIATA)
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(trip.destinationIATA)
                    Text("·")
                    Text(Format.weekday(trip.departure, in: .current))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let plan = trip.plan {
                    Text(summary(for: plan))
                        .font(.caption2)
                        .foregroundStyle(Theme.directionTint(plan.strategy.direction))
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func summary(for plan: CircadianPlan) -> String {
        switch plan.strategy.kind {
        case .noShiftNeeded: "No adjustment needed"
        case .stayOnHomeTime: "Staying on home time"
        case .partialShift, .fullShift:
            "\(plan.strategy.kind.displayName) · \(Format.shift(plan.strategy.targetShiftHours))"
        }
    }
}
