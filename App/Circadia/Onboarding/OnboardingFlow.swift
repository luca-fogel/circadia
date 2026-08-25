import SwiftUI
import SwiftData
import CircadianKit

/// The multi-step questionnaire that produces a trip.
///
/// Six short screens rather than one dense form. Each step asks for one kind of thing, can
/// be answered without scrolling on a phone, and refuses to advance until it has what the
/// engine actually needs.
struct OnboardingFlow: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(NotificationScheduler.self) private var scheduler

    @State private var draft = TripDraft()
    @State private var step: Step = .welcome
    @State private var isGenerating = false
    @State private var generated: (StoredTrip, CircadianPlan)?

    enum Step: Int, CaseIterable, Comparable {
        case welcome, chronotype, sleep, flight, aids, commitments

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: "Before you start"
            case .chronotype: "Your body clock"
            case .sleep: "Your usual night"
            case .flight: "Your flight"
            case .aids: "What you'll use"
            case .commitments: "Real life"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(
                    value: Double(step.rawValue + 1),
                    total: Double(Step.allCases.count)
                )
                .progressViewStyle(.linear)
                .padding(.horizontal)
                .padding(.bottom, 8)

                ScrollView {
                    Group {
                        switch step {
                        case .welcome: WelcomeStep(draft: draft)
                        case .chronotype: ChronotypeStep(draft: draft)
                        case .sleep: SleepStep(draft: draft)
                        case .flight: FlightStep(draft: draft)
                        case .aids: AidsStep(draft: draft)
                        case .commitments: CommitmentsStep(draft: draft)
                        }
                    }
                    .padding()
                    .padding(.bottom, 24)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                footer
            }
            .navigationTitle(step.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: Binding(
                get: { generated.map { PlanRoute(trip: $0.0) } },
                set: { if $0 == nil { generated = nil } }
            )) { route in
                PlanTimelineView(trip: route.trip)
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    private struct PlanRoute: Hashable {
        let trip: StoredTrip
        static func == (a: PlanRoute, b: PlanRoute) -> Bool { a.trip.id == b.trip.id }
        func hash(into hasher: inout Hasher) { hasher.combine(trip.id) }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if let blocker = blockingReason {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                if step != .welcome {
                    Button("Back") { withAnimation { retreat() } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step == .commitments ? "Build my plan" : "Continue") {
                    withAnimation { advance() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(blockingReason != nil || isGenerating)
                .overlay {
                    if isGenerating { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding()
        .background(.bar)
    }

    /// Why the Continue button is disabled, phrased for a human.
    private var blockingReason: String? {
        switch step {
        case .welcome:
            draft.acknowledgedDisclaimer ? nil : "Please confirm you understand this is not medical advice."
        case .chronotype:
            draft.questionnaireComplete ? nil : "Answer all five questions, or switch to picking your type directly."
        case .sleep:
            nil
        case .flight:
            if draft.origin == nil || draft.destination == nil {
                "Choose both airports."
            } else if draft.origin?.iata == draft.destination?.iata {
                "Origin and destination are the same airport."
            } else if !draft.flightIsValid {
                "Check the departure and arrival times — the flight time looks wrong."
            } else if !draft.returnIsValid {
                "Check the return flight times."
            } else {
                nil
            }
        case .aids, .commitments:
            nil
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            generate()
            return
        }
        step = next
    }

    private func retreat() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    private func generate() {
        guard let request = draft.makeRequest() else { return }
        isGenerating = true
        let plan = CircadianPlanner().makePlan(for: request)
        let trip = StoredTrip(request: request, plan: plan)
        context.insert(trip)
        try? context.save()

        Task {
            if scheduler.authorisation == .unknown {
                await scheduler.requestAuthorisation()
            }
            await scheduler.reschedule(for: plan, tripID: trip.id)
            isGenerating = false
            generated = (trip, plan)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let draft: TripDraft
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A plan for your body clock")
                    .font(.title2.weight(.semibold))
                Text("Answer a few questions and Circadia will work out when to seek light, when to avoid it, when to sleep and when a melatonin dose would help — hour by hour, from a few days before you fly until you have adapted.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclaimerPanel()

            Toggle(isOn: $acknowledged) {
                Text("I understand this is an educational tool and not medical advice.")
                    .font(.callout)
            }
            .onChange(of: acknowledged) { _, value in draft.acknowledgedDisclaimer = value }
        }
        .onAppear { acknowledged = draft.acknowledgedDisclaimer }
    }
}

private struct ChronotypeStep: View {
    @Bindable var draft: TripDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Where your body clock sits changes when light helps and when it hurts. Five questions is enough to place you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $draft.usesQuestionnaire) {
                Text("Answer questions").tag(true)
                Text("I know my type").tag(false)
            }
            .pickerStyle(.segmented)

            if draft.usesQuestionnaire {
                ForEach(ChronotypeQuestion.all) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.prompt)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            OptionRow(
                                label: option,
                                isSelected: draft.answers[question.id] == index
                            ) {
                                draft.answers[question.id] = index
                            }
                        }
                    }
                }
            } else {
                Picker("Your chronotype", selection: Binding(
                    get: { draft.manualChronotype ?? .intermediate },
                    set: { draft.manualChronotype = $0 }
                )) {
                    ForEach(Chronotype.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            ResultChip(
                label: "We'll plan for",
                value: draft.chronotype.displayName,
                systemImage: "person.fill.viewfinder"
            )
        }
    }
}

private struct SleepStep: View {
    @Bindable var draft: TripDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Your usual sleep times tell us where your temperature minimum sits — the pivot the whole plan turns on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                DatePicker("Usual bedtime", selection: $draft.bedtime, displayedComponents: .hourAndMinute)
                Divider().padding(.vertical, 10)
                DatePicker("Usual wake time", selection: $draft.wake, displayedComponents: .hourAndMinute)
                Divider().padding(.vertical, 10)
                Stepper("Age: \(draft.age)", value: $draft.age, in: 16...95)
            }
            .padding()
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            Text("Age matters because the circadian response to light is blunted in older adults, so the plan paces itself more gently.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ResultChip(
                label: "Estimated temperature minimum",
                value: draft.sleeper.estimatedCBTMin.description,
                systemImage: "thermometer.low"
            )
        }
    }
}

private struct FlightStep: View {
    @Bindable var draft: TripDraft
    @State private var locator = LocationProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                PlacePicker(title: "From", selection: $draft.origin)
                Divider().padding(.vertical, 12)
                PlacePicker(title: "To", selection: $draft.destination)
            }
            .padding()
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            Button {
                Task {
                    if let place = await locator.nearestAirport() { draft.origin = place }
                }
            } label: {
                Label("Use my current location", systemImage: "location")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)

            if let origin = draft.origin, let destination = draft.destination {
                VStack(spacing: 0) {
                    DatePicker("Departs", selection: $draft.departure)
                        .environment(\.timeZone, origin.timeZone)
                    Text("local time in \(origin.city)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Divider().padding(.vertical, 12)

                    DatePicker("Arrives", selection: $draft.arrival)
                        .environment(\.timeZone, destination.timeZone)
                    Text("local time in \(destination.city)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding()
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

                ZoneSummary(draft: draft, origin: origin, destination: destination)

                Toggle("I have a return flight", isOn: $draft.hasReturn)

                if draft.hasReturn {
                    VStack(spacing: 0) {
                        DatePicker("Flies home", selection: $draft.returnDeparture)
                            .environment(\.timeZone, destination.timeZone)
                        Divider().padding(.vertical, 12)
                        DatePicker("Lands home", selection: $draft.returnArrival)
                            .environment(\.timeZone, origin.timeZone)
                    }
                    .padding()
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

                    Text("Knowing when you come home is what lets Circadia tell you whether shifting is worth it at all. For a short trip, staying on home time often beats adapting twice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ZoneSummary: View {
    let draft: TripDraft
    let origin: Place
    let destination: Place

    var body: some View {
        let flight = Flight(origin: origin, destination: destination, departure: draft.departure, arrival: draft.arrival)
        HStack(spacing: 14) {
            Label(draft.blockTimeDescription, systemImage: "airplane")
            Divider().frame(height: 16)
            Label(
                String(format: "%+.0f h clock change", flight.rawZoneDifferenceHours),
                systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
            )
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct AidsStep: View {
    @Bindable var draft: TripDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Include melatonin timing", isOn: $draft.usesMelatonin)
                if draft.usesMelatonin {
                    Picker("Dose", selection: $draft.melatoninDose) {
                        Text("0.5 mg").tag(0.5)
                        Text("3 mg").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    Text(draft.melatoninDose < 1.5
                         ? "The low dose is the better choice for most people: it produces a similar shift with less next-day grogginess, and it wants to be taken slightly later."
                         : "The higher dose needs to be taken earlier in the afternoon to advance your clock, and is more likely to make you drowsy in the evening.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Toggle("Include caffeine timing", isOn: $draft.usesCaffeine)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("I can use a bright lamp indoors", isOn: $draft.allowLightBox)
                Text("When the ideal light window falls after dark, Circadia can suggest a 10,000 lux lamp instead. Turn this off and it will only ever send you outdoors.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclaimerPanel()
        }
    }
}

private struct CommitmentsStep: View {
    @Bindable var draft: TripDraft
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The ideal schedule and your actual week rarely agree. Tell Circadia what is fixed and it will move the windows around it — within the limits of what still works — instead of giving you advice you cannot follow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.constraints.isEmpty {
                Text("Nothing added. That's fine — you can add commitments later.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(draft.constraints) { constraint in
                    ConstraintRow(constraint: constraint) {
                        draft.constraints.removeAll { $0.id == constraint.id }
                    }
                }
            }

            Button {
                isAdding = true
            } label: {
                Label("Add a commitment", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $isAdding) {
            ConstraintEditor { draft.constraints.append($0) }
        }
    }
}

// MARK: - Small shared controls

struct OptionRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.3)),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ResultChip: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.medium))
            }
            Spacer()
        }
        .padding(12)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
