import Foundation
import SwiftData
import CircadianKit

/// A saved trip.
///
/// The engine's types are pure value types that already conform to `Codable`, so the
/// request and the generated plan are stored as encoded blobs rather than mirrored into a
/// parallel SwiftData object graph. That keeps exactly one definition of a plan in the
/// codebase, and it means an engine change can never silently disagree with the schema.
@Model
final class StoredTrip {

    #Index<StoredTrip>([\.departure])

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// Denormalised for list display and sorting without decoding the whole plan.
    var originIATA: String
    var originCity: String
    var destinationIATA: String
    var destinationCity: String
    var departure: Date
    var returnArrival: Date?

    private var requestData: Data
    private var planData: Data?

    var notificationsEnabled: Bool

    init(request: TripPlanRequest, plan: CircadianPlan) {
        self.id = plan.id
        self.createdAt = .now
        self.originIATA = request.outbound.origin.iata
        self.originCity = request.outbound.origin.city
        self.destinationIATA = request.outbound.destination.iata
        self.destinationCity = request.outbound.destination.city
        self.departure = request.outbound.departure
        self.returnArrival = request.homebound?.arrival
        self.requestData = (try? JSONEncoder().encode(request)) ?? Data()
        self.planData = try? JSONEncoder().encode(plan)
        self.notificationsEnabled = true
    }

    var request: TripPlanRequest? {
        try? JSONDecoder().decode(TripPlanRequest.self, from: requestData)
    }

    var plan: CircadianPlan? {
        guard let planData else { return nil }
        return try? JSONDecoder().decode(CircadianPlan.self, from: planData)
    }

    /// Re-runs the engine and replaces the cached plan. Used when the engine changes or
    /// the user edits the trip, so a stale cache can never outlive its inputs.
    func regeneratePlan(using planner: CircadianPlanner = CircadianPlanner()) {
        guard let request else { return }
        let fresh = planner.makePlan(for: request)
        planData = try? JSONEncoder().encode(fresh)
    }

    var title: String { "\(originCity) → \(destinationCity)" }

    /// The last instant the plan says anything about.
    var planEnd: Date {
        plan?.days.last?.localDayStart.addingTimeInterval(24 * 3600) ?? departure
    }

    var isPast: Bool { planEnd < .now }

    /// Where the traveller is in the plan right now, or `nil` if it has not started.
    func currentDay(now: Date = .now) -> DayPlan? {
        plan?.days.first {
            now >= $0.localDayStart && now < $0.localDayStart.addingTimeInterval(24 * 3600)
        }
    }
}
