import SwiftUI
import CircadianKit

/// The app's visual vocabulary.
///
/// One idea holds it together: this is an app about the difference between night and day,
/// so colour carries meaning rather than decoration. Warm amber is light you want, deep
/// indigo is darkness you want, and everything else stays quiet so those two read clearly.
enum Theme {

    // MARK: - Palette

    static let seekLight = Color(red: 0.99, green: 0.72, blue: 0.20)
    static let artificialLight = Color(red: 0.96, green: 0.82, blue: 0.45)
    /// Light to be avoided. Deliberately *lighter* than `nightFill`: the semantics are
    /// "darkness", but a bar the same colour as the night background it is drawn on is a
    /// bar nobody can see.
    static let avoidLight = Color(red: 0.42, green: 0.47, blue: 0.74)
    static let mitigate = Color(red: 0.58, green: 0.61, blue: 0.76)
    static let sleep = Color(red: 0.29, green: 0.44, blue: 0.78)
    static let nap = Color(red: 0.36, green: 0.65, blue: 0.72)
    static let melatonin = Color(red: 0.76, green: 0.36, blue: 0.72)
    static let caffeine = Color(red: 0.65, green: 0.47, blue: 0.31)
    static let flight = Color.secondary
    static let milestone = Color(red: 0.20, green: 0.63, blue: 0.50)

    static func color(for kind: PlanEvent.Kind) -> Color {
        switch kind {
        case .seekLight: seekLight
        case .seekArtificialLight: artificialLight
        case .avoidLight: avoidLight
        case .mitigateLight: mitigate
        case .sleep: sleep
        case .nap: nap
        case .melatonin: melatonin
        case .caffeineOK, .caffeineAvoid: caffeine
        case .flight: flight
        case .milestone: milestone
        }
    }

    // MARK: - Day and night

    /// Daytime sky, used to shade the part of a ribbon or wheel where the sun is up.
    static let daylight = LinearGradient(
        colors: [Color(red: 0.53, green: 0.76, blue: 0.94), Color(red: 0.86, green: 0.91, blue: 0.97)],
        startPoint: .top, endPoint: .bottom
    )

    /// Night, used for everything outside civil twilight.
    static let night = LinearGradient(
        colors: [Color(red: 0.09, green: 0.11, blue: 0.22), Color(red: 0.16, green: 0.18, blue: 0.32)],
        startPoint: .top, endPoint: .bottom
    )

    static let nightFill = Color(red: 0.12, green: 0.14, blue: 0.26)
    static let dayFill = Color(red: 0.72, green: 0.85, blue: 0.96)

    static func directionTint(_ direction: ShiftDirection) -> Color {
        switch direction {
        case .advance: Color(red: 0.93, green: 0.55, blue: 0.24)
        case .delay: Color(red: 0.34, green: 0.51, blue: 0.85)
        case .none: .secondary
        }
    }

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 16
    static let ribbonHeight: CGFloat = 44
}

/// Shared formatters. Building a `DateFormatter` inside a `View` body is a classic way to
/// make a scrolling list stutter, so they live here and are reused.
enum Format {

    static func time(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func range(_ interval: TimeWindow, in zone: TimeZone) -> String {
        "\(time(interval.start, in: zone))–\(time(interval.end, in: zone))"
    }

    static func weekday(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    static func shortDay(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    static func dayNumber(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "d"
        return f.string(from: date)
    }

    /// Signed hours, e.g. `+2.5 h` / `−1.0 h`. Uses a real minus sign.
    static func shift(_ hours: Double) -> String {
        let sign = hours < 0 ? "\u{2212}" : "+"
        return String(format: "%@%.1f h", sign, abs(hours))
    }

    static func hours(_ hours: Double) -> String {
        String(format: "%.1f h", hours)
    }
}
