import Foundation
import UserNotifications
import Observation
import CircadianKit

/// Schedules a local notification at the start of every plan event.
///
/// The interesting constraint is a platform one: iOS keeps at most **64 pending local
/// notifications per app** and silently drops the rest. A two-week plan can easily
/// generate two hundred events, so the scheduler cannot simply enqueue everything — it
/// ranks by how much each event matters and spends its budget on the top of the list.
@MainActor
@Observable
final class NotificationScheduler {

    /// Apple's documented ceiling on pending local notifications, less a little headroom.
    static let budget = 60

    enum Authorisation: Equatable {
        case unknown, denied, granted, provisional
    }

    var authorisation: Authorisation = .unknown
    var lastError: String?
    var scheduledCount = 0

    private let center = UNUserNotificationCenter.current()

    func refreshAuthorisation() async {
        let settings = await center.notificationSettings()
        authorisation = switch settings.authorizationStatus {
        case .authorized: .granted
        case .provisional, .ephemeral: .provisional
        case .denied: .denied
        default: .unknown
        }
    }

    @discardableResult
    func requestAuthorisation() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorisation = granted ? .granted : .denied
            return granted
        } catch {
            lastError = error.localizedDescription
            authorisation = .denied
            return false
        }
    }

    /// Replaces all notifications for `plan` with a freshly ranked set.
    func reschedule(for plan: CircadianPlan, tripID: UUID) async {
        cancel(tripID: tripID)
        guard authorisation == .granted || authorisation == .provisional else { return }

        let selected = Self.prioritise(plan.upcomingEvents(), budget: Self.budget)
        for event in selected {
            let content = UNMutableNotificationContent()
            content.title = Self.notificationTitle(for: event)
            content.body = event.detail
            content.sound = event.kind == .sleep || event.kind == .melatonin ? nil : .default
            content.threadIdentifier = tripID.uuidString
            content.userInfo = ["tripID": tripID.uuidString, "eventID": event.id.uuidString]

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = event.displayTimeZone
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: event.interval.start
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            do {
                try await center.add(UNNotificationRequest(
                    identifier: Self.identifier(tripID: tripID, eventID: event.id),
                    content: content,
                    trigger: trigger
                ))
            } catch {
                lastError = error.localizedDescription
            }
        }
        scheduledCount = selected.count
    }

    func cancel(tripID: UUID) {
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(tripID.uuidString) }
            Task { @MainActor in
                self.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        scheduledCount = 0
    }

    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    // MARK: - Budgeting

    static func identifier(tripID: UUID, eventID: UUID) -> String {
        "\(tripID.uuidString)-\(eventID.uuidString)"
    }

    /// Chooses which events get a notification.
    ///
    /// Sorted by importance first and time second, then truncated — so a plan that
    /// overruns the budget loses its caffeine reminders on day nine rather than its
    /// light windows tomorrow morning.
    static func prioritise(_ events: [PlanEvent], budget: Int) -> [PlanEvent] {
        events
            .filter(\.kind.isActionable)
            .sorted { lhs, rhs in
                if lhs.kind.notificationPriority != rhs.kind.notificationPriority {
                    return lhs.kind.notificationPriority > rhs.kind.notificationPriority
                }
                return lhs.interval.start < rhs.interval.start
            }
            .prefix(budget)
            .sorted { $0.interval.start < $1.interval.start }
    }

    static func notificationTitle(for event: PlanEvent) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = event.displayTimeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let end = formatter.string(from: event.interval.end)

        return switch event.kind {
        case .seekLight, .seekArtificialLight: "\(event.title) — until \(end)"
        case .avoidLight, .mitigateLight: "\(event.title) — until \(end)"
        case .sleep: "Time for bed"
        case .nap: "Nap window"
        case .melatonin: event.title
        case .caffeineOK: "Caffeine is fine until \(end)"
        default: event.title
        }
    }
}
