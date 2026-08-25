import Foundation
import Observation
import SwiftUI
import CircadianKit

/// Mutable state for the onboarding questionnaire, converted into a `TripPlanRequest` at
/// the end. Kept separate from the engine's value types so a half-finished questionnaire
/// can never be mistaken for a valid trip.
@MainActor
@Observable
final class TripDraft {

    // Step 1
    var acknowledgedDisclaimer = false

    // Step 2 — chronotype
    var answers: [Int] = Array(repeating: -1, count: ChronotypeQuestion.all.count)
    var manualChronotype: Chronotype?
    var usesQuestionnaire = true

    var chronotype: Chronotype {
        if let manualChronotype, !usesQuestionnaire { return manualChronotype }
        return ChronotypeQuestion.chronotype(for: answers)
    }

    var questionnaireComplete: Bool {
        !usesQuestionnaire || answers.allSatisfy { $0 >= 0 }
    }

    // Step 3 — habitual sleep. Stored as instants so `DatePicker` can bind directly; only
    // the time-of-day component is ever read.
    var bedtime: Date = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: .now) ?? .now
    var wake: Date = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    var age: Int = 30

    // Step 4 — the flight
    var origin: Place?
    var destination: Place?
    var departure: Date = defaultDeparture()
    var arrival: Date = defaultDeparture().addingTimeInterval(8 * 3600)
    var hasReturn = false
    var returnDeparture: Date = defaultDeparture().addingTimeInterval(7 * 86400)
    var returnArrival: Date = defaultDeparture().addingTimeInterval(7 * 86400 + 8 * 3600)

    // Step 5 — aids
    var usesMelatonin = true
    var melatoninDose: Double = 0.5
    var usesCaffeine = true
    var allowLightBox = true

    // Step 6 — constraints
    var constraints: [PracticalityConstraint] = []

    var flightIsValid: Bool {
        guard let origin, let destination, origin.iata != destination.iata else { return false }
        let block = arrival.timeIntervalSince(departure)
        return block > 15 * 60 && block < 30 * 3600
    }

    var returnIsValid: Bool {
        guard hasReturn else { return true }
        let block = returnArrival.timeIntervalSince(returnDeparture)
        return returnDeparture > arrival && block > 15 * 60 && block < 30 * 3600
    }

    var blockTimeDescription: String {
        let hours = arrival.timeIntervalSince(departure) / 3600
        guard hours > 0 else { return "Arrival must be after departure" }
        return String(format: "%.0f h %02.0f min in the air", hours.rounded(.down), (hours - hours.rounded(.down)) * 60)
    }

    /// Clock time from a picked instant, read in the device's zone — the user set these
    /// pickers while at home, so the device zone is the right frame for "my bedtime".
    private func clockTime(from date: Date) -> ClockTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return ClockTime(hour: components.hour ?? 23, minute: components.minute ?? 0)
    }

    var sleeper: Sleeper {
        Sleeper(
            chronotype: chronotype,
            habitualBedtime: clockTime(from: bedtime),
            habitualWake: clockTime(from: wake),
            age: age,
            usesMelatonin: usesMelatonin,
            usesCaffeine: usesCaffeine
        )
    }

    func makeRequest() -> TripPlanRequest? {
        guard let origin, let destination, flightIsValid, returnIsValid else { return nil }

        var options = PlanOptions()
        options.melatoninMilligrams = melatoninDose
        options.allowArtificialBrightLight = allowLightBox

        return TripPlanRequest(
            outbound: Flight(origin: origin, destination: destination, departure: departure, arrival: arrival),
            homebound: hasReturn
                ? Flight(origin: destination, destination: origin, departure: returnDeparture, arrival: returnArrival)
                : nil,
            sleeper: sleeper,
            constraints: constraints,
            options: options
        )
    }
}

/// A sensible default departure: a week out, at ten in the morning.
///
/// A free function rather than a static, because `@Observable` rewrites stored properties
/// and `Self` may not be referenced from what remains of their initializers.
func defaultDeparture() -> Date {
    let calendar = Calendar.current
    let inAWeek = calendar.date(byAdding: .day, value: 7, to: .now) ?? .now
    return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: inAWeek) ?? inAWeek
}

/// A short morningness questionnaire.
///
/// Written in the spirit of the reduced Morningness–Eveningness Questionnaire (Adan &
/// Almirall 1991) rather than reproducing it: the item wording here is original, and the
/// five-to-twenty-five total is mapped onto the same five categories the rMEQ uses.
struct ChronotypeQuestion: Identifiable {
    let id: Int
    let prompt: String
    /// Options ordered from most evening (score 1) to most morning (score 5).
    let options: [String]

    static let all: [ChronotypeQuestion] = [
        ChronotypeQuestion(
            id: 0,
            prompt: "With a completely free day and no alarm, when would you get up?",
            options: ["After 11:00", "9:30–11:00", "8:00–9:30", "6:30–8:00", "Before 6:30"]
        ),
        ChronotypeQuestion(
            id: 1,
            prompt: "In the first half hour after waking, how do you feel?",
            options: ["Very tired", "Fairly tired", "Reasonably alert", "Quite alert", "Wide awake"]
        ),
        ChronotypeQuestion(
            id: 2,
            prompt: "When do you start to feel tired in the evening?",
            options: ["After 02:00", "00:45–02:00", "22:45–00:45", "21:00–22:45", "Before 21:00"]
        ),
        ChronotypeQuestion(
            id: 3,
            prompt: "At what time of day do you feel at your best?",
            options: ["Late evening or night", "Evening", "Afternoon", "Late morning", "Early morning"]
        ),
        ChronotypeQuestion(
            id: 4,
            prompt: "Do you think of yourself as a morning or an evening person?",
            options: ["Definitely evening", "More evening", "Neither", "More morning", "Definitely morning"]
        )
    ]

    /// Sums the answers and maps onto the rMEQ's five categories.
    static func chronotype(for answers: [Int]) -> Chronotype {
        let answered = answers.filter { $0 >= 0 }
        guard !answered.isEmpty else { return .intermediate }
        // Each answer contributes 1–5; scale a partial questionnaire up to the full range
        // so the category does not lurch about while the user is still answering.
        let raw = answered.reduce(0) { $0 + $1 + 1 }
        let scaled = Double(raw) / Double(answered.count) * Double(all.count)
        return Chronotype(rMEQScore: Int(scaled.rounded()))
    }
}
