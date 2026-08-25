import Foundation

/// Arithmetic on the circular 24-hour clock.
///
/// Circadian phase is inherently modular: 23:30 and 00:30 are one hour apart, not
/// twenty-three. Every phase comparison in the engine goes through these helpers so
/// that the wrap-around is handled in exactly one place.
public enum CircadianHours {

    /// Normalises `hours` into `[0, 24)`.
    public static func wrap24(_ hours: Double) -> Double {
        let r = hours.truncatingRemainder(dividingBy: 24)
        return r < 0 ? r + 24 : r
    }

    /// Normalises `hours` into `(-12, 12]` — the *signed* distance around the clock.
    ///
    /// This is the form the phase-response curve is indexed by: a light pulse two
    /// hours before the temperature minimum is at `-2`, not at `+22`.
    public static func signedOffset(_ hours: Double) -> Double {
        var r = wrap24(hours)
        if r > 12 { r -= 24 }
        return r
    }

    /// Shortest signed distance from `a` to `b` around the clock, in `(-12, 12]`.
    public static func delta(from a: Double, to b: Double) -> Double {
        signedOffset(b - a)
    }

    /// Circular interpolation from `a` towards `b`, taking the short way round.
    public static func interpolate(from a: Double, to b: Double, fraction: Double) -> Double {
        wrap24(a + delta(from: a, to: b) * fraction)
    }
}

/// A clock time expressed as fractional hours since local midnight.
///
/// Used for habitual schedules and user constraints, which are naturally "10:30pm
/// every night" rather than a specific instant.
public struct ClockTime: Hashable, Sendable, Codable, Comparable {
    /// Fractional hours in `[0, 24)`.
    public var hours: Double

    public init(hours: Double) {
        self.hours = CircadianHours.wrap24(hours)
    }

    public init(hour: Int, minute: Int = 0) {
        self.init(hours: Double(hour) + Double(minute) / 60)
    }

    public var hour: Int { Int(hours.rounded(.down)) }
    public var minute: Int { Int(((hours - Double(hour)) * 60).rounded()) % 60 }

    public static func < (lhs: ClockTime, rhs: ClockTime) -> Bool { lhs.hours < rhs.hours }

    public func adding(hours delta: Double) -> ClockTime {
        ClockTime(hours: hours + delta)
    }

    /// Signed distance to `other`, in `(-12, 12]`.
    public func signedDistance(to other: ClockTime) -> Double {
        CircadianHours.delta(from: hours, to: other.hours)
    }
}

extension ClockTime: CustomStringConvertible {
    public var description: String { String(format: "%02d:%02d", hour, minute) }
}

/// A half-open interval of instants, `[start, end)`.
///
/// Named `TimeWindow` rather than `DateInterval` on purpose: Foundation already has a
/// `DateInterval`, and shadowing it makes every file importing both this module and
/// Foundation ambiguous at the point of use.
public struct TimeWindow: Hashable, Sendable, Codable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var durationHours: Double { duration / 3600 }
    public var midpoint: Date { start.addingTimeInterval(duration / 2) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public func intersects(_ other: TimeWindow) -> Bool {
        start < other.end && other.start < end
    }

    public func intersection(_ other: TimeWindow) -> TimeWindow? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return s < e ? TimeWindow(start: s, end: e) : nil
    }

    public func shifted(byHours hours: Double) -> TimeWindow {
        TimeWindow(start: start.addingTimeInterval(hours * 3600),
                     end: end.addingTimeInterval(hours * 3600))
    }

    /// Splits off the portion of `self` that lies outside `other`.
    public func subtracting(_ other: TimeWindow) -> [TimeWindow] {
        guard intersects(other) else { return [self] }
        var pieces: [TimeWindow] = []
        if start < other.start { pieces.append(TimeWindow(start: start, end: other.start)) }
        if other.end < end { pieces.append(TimeWindow(start: other.end, end: end)) }
        return pieces
    }
}
