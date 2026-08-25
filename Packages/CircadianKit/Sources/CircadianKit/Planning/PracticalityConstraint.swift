import Foundation

/// A real-world commitment that the physiologically ideal schedule has to bend around.
///
/// The engine never silently ignores one of these, and never lets one push a window
/// somewhere that would make it useless: constraints are satisfied by *nudging within
/// physiologically acceptable bounds*, and if that is impossible the resulting loss of
/// efficacy is reported rather than hidden.
public struct PracticalityConstraint: Hashable, Sendable, Codable, Identifiable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A commitment that rules out sleeping or napping — a meeting, a dinner, a shift.
        case mustBeAwake
        /// Bright light you cannot escape: an office, a lit conference room, a cabin with
        /// the blinds up. Avoid-light advice here is downgraded to mitigation
        /// (blue-blocking glasses, sitting away from windows) and the residual wrong-way
        /// shift is subtracted from the day's progress.
        case brightLightUnavoidable
        /// Bright light you cannot obtain: a windowless room, a night arrival, bad weather.
        /// Seek-light advice here has to move or fall back to a light box.
        case brightLightUnavailable
        /// Do not prescribe melatonin in this window (or at all, if it spans the day).
        case noMelatonin
        /// Do not prescribe caffeine in this window.
        case noCaffeine

        public var displayName: String {
            switch self {
            case .mustBeAwake: "Must be awake"
            case .brightLightUnavoidable: "Can't avoid bright light"
            case .brightLightUnavailable: "Can't get bright light"
            case .noMelatonin: "No melatonin"
            case .noCaffeine: "No caffeine"
            }
        }

        public var symbolName: String {
            switch self {
            case .mustBeAwake: "person.crop.circle.badge.exclamationmark"
            case .brightLightUnavoidable: "sun.max.trianglebadge.exclamationmark"
            case .brightLightUnavailable: "lightbulb.slash"
            case .noMelatonin: "pills.slash"
            case .noCaffeine: "cup.and.saucer"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Plan day this applies to, where 0 is the outbound departure day. `nil` = every day.
    public var dayIndex: Int?
    /// Start of the window, as local clock time at whichever place governs that day.
    public var from: ClockTime
    /// End of the window. May wrap past midnight.
    public var to: ClockTime
    /// What the user called it, echoed back in the plan so adjustments are explicable.
    public var label: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        dayIndex: Int? = nil,
        from: ClockTime,
        to: ClockTime,
        label: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.dayIndex = dayIndex
        self.from = from
        self.to = to
        self.label = label.isEmpty ? kind.displayName : label
    }

    /// Resolves this constraint to absolute instants on a given local day.
    ///
    /// Returns `nil` when the constraint does not apply to `dayIndex`.
    public func resolve(dayIndex index: Int, localDayStart: Date, calendar: Calendar) -> TimeWindow? {
        if let day = dayIndex, day != index { return nil }
        let start = localDayStart.addingTimeInterval(from.hours * 3600)
        var end = localDayStart.addingTimeInterval(to.hours * 3600)
        if end <= start { end = end.addingTimeInterval(24 * 3600) }  // wrapped past midnight
        return TimeWindow(start: start, end: end)
    }

    /// Whether a whole-day constraint of this kind blocks an intervention outright.
    public var isBlanket: Bool {
        from.hours == 0 && (to.hours == 0 || to.hours >= 23.99)
    }
}

/// The outcome of asking the practicality filter to place a window.
struct FilteredWindow {
    /// The window actually prescribed.
    var interval: TimeWindow
    /// Predicted shift the prescribed window achieves, in hours (signed).
    var predictedShift: Double
    /// Predicted shift the *unconstrained* ideal would have achieved.
    var idealShift: Double
    /// Label of the constraint that moved it, if any.
    var movedBy: String?
    /// How bright the light actually is, after any downgrade to a light box.
    var lux: Double
    /// Whether the prescription had to fall back to artificial light.
    var isArtificial: Bool

    /// `predictedShift / idealShift`, clamped to `0...1`.
    var efficacy: Double {
        guard abs(idealShift) > 1e-6 else { return 1 }
        return min(1, max(0, predictedShift / idealShift))
    }
}
