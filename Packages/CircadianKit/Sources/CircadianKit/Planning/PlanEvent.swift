import Foundation

/// One instruction on the timeline.
public struct PlanEvent: Identifiable, Hashable, Sendable, Codable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Get outdoors. The strongest lever in the whole plan.
        case seekLight
        /// Ideal window falls outside daylight, so use a light box or the brightest
        /// indoor light available.
        case seekArtificialLight
        /// Keep it dark: sunglasses, blinds down, eye mask, dim screens.
        case avoidLight
        /// Bright light you cannot escape — mitigate rather than avoid.
        case mitigateLight
        case sleep
        case nap
        case melatonin
        case caffeineOK
        case caffeineAvoid
        /// The flight itself, for context on the timeline.
        case flight
        /// A note rather than an action: arrival, adaptation reached, strategy change.
        case milestone

        public var displayName: String {
            switch self {
            case .seekLight: "Get bright light"
            case .seekArtificialLight: "Bright light indoors"
            case .avoidLight: "Avoid bright light"
            case .mitigateLight: "Dim the light you can't avoid"
            case .sleep: "Sleep"
            case .nap: "Nap"
            case .melatonin: "Melatonin"
            case .caffeineOK: "Caffeine window"
            case .caffeineAvoid: "No caffeine"
            case .flight: "Flight"
            case .milestone: "Milestone"
            }
        }

        public var symbolName: String {
            switch self {
            case .seekLight: "sun.max.fill"
            case .seekArtificialLight: "lamp.desk.fill"
            case .avoidLight: "eye.slash.fill"
            case .mitigateLight: "sunglasses.fill"
            case .sleep: "bed.double.fill"
            case .nap: "zzz"
            case .melatonin: "pills.fill"
            case .caffeineOK: "cup.and.saucer.fill"
            case .caffeineAvoid: "mug.fill"
            case .flight: "airplane"
            case .milestone: "flag.fill"
            }
        }

        /// Whether the event is worth a push notification.
        public var isActionable: Bool {
            switch self {
            case .flight, .caffeineAvoid: false
            default: true
            }
        }

        /// Ordering weight for the notification budget: iOS keeps at most 64 pending
        /// local notifications, so the plan has to know what matters most.
        public var notificationPriority: Int {
            switch self {
            case .seekLight, .seekArtificialLight: 100
            case .avoidLight: 90
            case .sleep: 80
            case .melatonin: 70
            case .nap: 50
            case .mitigateLight: 40
            case .caffeineOK: 20
            case .milestone: 15
            case .caffeineAvoid, .flight: 0
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var interval: TimeWindow
    /// Day of the plan, where 0 is the outbound departure day at the origin.
    public var dayIndex: Int
    public var title: String
    /// One or two sentences explaining *why*, which is also the notification body.
    public var detail: String
    /// Zone the event should be displayed in — origin before the flight, destination after.
    public var displayTimeZoneIdentifier: String
    /// Signed contribution to the day's phase shift, in hours. `nil` for events that do
    /// not act on the clock directly (caffeine, milestones, the flight).
    public var predictedShiftHours: Double?
    /// Set when the practicality filter moved this window, naming the constraint.
    public var adjustedForConstraint: String?
    /// Fraction of the unconstrained ideal effect retained, `0...1`.
    public var efficacy: Double
    /// Illuminance the advice assumes, in lux, for light events.
    public var assumedLux: Double?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        interval: TimeWindow,
        dayIndex: Int,
        title: String,
        detail: String,
        displayTimeZoneIdentifier: String,
        predictedShiftHours: Double? = nil,
        adjustedForConstraint: String? = nil,
        efficacy: Double = 1,
        assumedLux: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.interval = interval
        self.dayIndex = dayIndex
        self.title = title
        self.detail = detail
        self.displayTimeZoneIdentifier = displayTimeZoneIdentifier
        self.predictedShiftHours = predictedShiftHours
        self.adjustedForConstraint = adjustedForConstraint
        self.efficacy = efficacy
        self.assumedLux = assumedLux
    }

    public var displayTimeZone: TimeZone {
        TimeZone(identifier: displayTimeZoneIdentifier) ?? .current
    }

    /// True when a constraint cost this window a meaningful part of its effect.
    public var isCompromised: Bool { efficacy < 0.85 }
}

/// One local day of the plan.
public struct DayPlan: Identifiable, Hashable, Sendable, Codable {
    /// 0 is the outbound departure day; negative days are preparation.
    public var dayIndex: Int
    public var id: Int { dayIndex }
    /// Local midnight that starts this day, at `place`.
    public var localDayStart: Date
    /// The place whose clock and daylight govern this day.
    public var place: Place
    /// Instant of the temperature minimum at the start of the day.
    public var cbtMinAtStart: Date
    /// Instant of the temperature minimum after the day's interventions.
    public var cbtMinAtEnd: Date
    /// Signed shift the day is predicted to achieve, in hours.
    public var achievedShiftHours: Double
    /// Signed shift accumulated since the plan began.
    public var cumulativeShiftHours: Double
    /// Signed shift still outstanding at the end of the day.
    public var remainingShiftHours: Double
    public var events: [PlanEvent]
    /// Sunrise/sunset structure of the day, for shading the timeline.
    public var sunrise: Date?
    public var sunset: Date?
    public var isPolarDay: Bool
    public var isPolarNight: Bool
    /// Short label such as "2 days before departure".
    public var title: String
    /// Notes about compromises or milestones on this day.
    public var notes: [String]

    public var timeZone: TimeZone { place.timeZone }
}

/// A complete jet-lag plan.
public struct CircadianPlan: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var request: TripPlanRequest
    public var strategy: ShiftStrategy
    public var days: [DayPlan]
    /// Total signed shift the plan is predicted to achieve.
    public var achievedShiftHours: Double
    /// Day index by which the pacemaker is within half an hour of the target, if reached.
    public var dayAdaptationReached: Int?
    /// Signed hours of misalignment left at the end of the plan.
    public var residualMisalignmentHours: Double
    /// Windows the practicality filter had to compromise.
    public var compromisedEventCount: Int

    public var events: [PlanEvent] { days.flatMap(\.events).sorted { $0.interval.start < $1.interval.start } }

    /// Events still in the future, for notification scheduling.
    public func upcomingEvents(after now: Date = Date()) -> [PlanEvent] {
        events.filter { $0.interval.start > now }
    }

    public static let disclaimer = """
        This is an independent, educational circadian-shift planner. It is not medical \
        advice, it is not a substitute for talking to a clinician, and it is not \
        affiliated with, endorsed by, or derived from Timeshifter or any commercial \
        jet-lag product. Its recommendations come from published human phase-response \
        research applied by a simplified model, and individual responses vary widely.
        """
}
