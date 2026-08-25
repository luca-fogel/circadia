import Foundation

/// Morningness–eveningness preference.
///
/// The five levels mirror the categories of the reduced Morningness–Eveningness
/// Questionnaire (rMEQ, Adan & Almirall 1991), so a score from the onboarding
/// questionnaire maps onto them directly.
public enum Chronotype: String, CaseIterable, Sendable, Codable, Identifiable {
    case definiteMorning
    case moderateMorning
    case intermediate
    case moderateEvening
    case definiteEvening

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .definiteMorning: "Definite morning type"
        case .moderateMorning: "Moderate morning type"
        case .intermediate: "Intermediate"
        case .moderateEvening: "Moderate evening type"
        case .definiteEvening: "Definite evening type"
        }
    }

    public var shortName: String {
        switch self {
        case .definiteMorning: "Early bird"
        case .moderateMorning: "Somewhat early"
        case .intermediate: "Neither"
        case .moderateEvening: "Somewhat late"
        case .definiteEvening: "Night owl"
        }
    }

    /// Classifies an rMEQ total score (range 4–25; lower = more evening).
    ///
    /// Cut-offs from Adan & Almirall (1991).
    public init(rMEQScore score: Int) {
        switch score {
        case ...7: self = .definiteEvening
        case 8...11: self = .moderateEvening
        case 12...17: self = .intermediate
        case 18...21: self = .moderateMorning
        default: self = .definiteMorning
        }
    }

    /// Hours between the core-body-temperature minimum and habitual wake time.
    ///
    /// Morning types entrain with a *longer* interval between their temperature
    /// nadir and wake-up than evening types (Duffy, Rimmer & Czeisler 2001; Duffy
    /// et al. 1999) — i.e. an early bird's nadir sits further before the alarm.
    ///
    /// Note this is the opposite sign convention to the naive "night owls have a
    /// later nadir relative to wake" intuition: owls wake at an *earlier* circadian
    /// phase because social schedules truncate their biological night.
    var cbtMinToWakeHours: Double {
        switch self {
        case .definiteMorning: 3.2
        case .moderateMorning: 2.7
        case .intermediate: 2.2
        case .moderateEvening: 1.8
        case .definiteEvening: 1.4
        }
    }

    /// Free-running circadian period is slightly longer in evening types, which is
    /// why delays come more easily to them than advances.
    ///
    /// Values bracket the ~24.15 h population mean measured under forced desynchrony
    /// (Czeisler et al. 1999).
    var intrinsicPeriodHours: Double {
        switch self {
        case .definiteMorning: 24.02
        case .moderateMorning: 24.08
        case .intermediate: 24.15
        case .moderateEvening: 24.22
        case .definiteEvening: 24.28
        }
    }
}

/// A person's habitual sleep timing and light sensitivity.
public struct Sleeper: Hashable, Sendable, Codable {
    public var chronotype: Chronotype
    /// Habitual sleep onset in home local time.
    public var habitualBedtime: ClockTime
    /// Habitual wake time in home local time.
    public var habitualWake: ClockTime
    /// Age in years. Older adults show a blunted phase-shifting response to light
    /// (Duffy et al. 2007; Sletten et al. 2009), scaled via `lightSensitivity`.
    public var age: Int
    public var usesMelatonin: Bool
    public var usesCaffeine: Bool

    public init(
        chronotype: Chronotype = .intermediate,
        habitualBedtime: ClockTime = ClockTime(hour: 23),
        habitualWake: ClockTime = ClockTime(hour: 7),
        age: Int = 30,
        usesMelatonin: Bool = true,
        usesCaffeine: Bool = true
    ) {
        self.chronotype = chronotype
        self.habitualBedtime = habitualBedtime
        self.habitualWake = habitualWake
        self.age = age
        self.usesMelatonin = usesMelatonin
        self.usesCaffeine = usesCaffeine
    }

    /// Habitual time in bed, in hours (always positive, wrapping midnight).
    public var sleepDurationHours: Double {
        let d = CircadianHours.wrap24(habitualWake.hours - habitualBedtime.hours)
        // A zero-length or absurd schedule is treated as a nominal 8 h night.
        return (d < 3 || d > 14) ? 8 : d
    }

    /// Midpoint of the habitual sleep episode.
    public var sleepMidpoint: ClockTime {
        habitualBedtime.adding(hours: sleepDurationHours / 2)
    }

    /// Estimated phase of the core-body-temperature minimum in home local time.
    ///
    /// Two published anchors disagree slightly, so the engine averages them
    /// circularly rather than picking a favourite:
    ///
    /// 1. CBTmin sits a chronotype-dependent interval before habitual wake
    ///    (Eastman & Burgess 2009 use ~2–3 h for typical sleepers).
    /// 2. Dim-light melatonin onset precedes habitual sleep onset by ~2.5 h and
    ///    CBTmin follows DLMO by ~7 h (Burgess et al. 2003).
    ///
    /// For a 23:00–07:00 sleeper of intermediate chronotype the two estimates are
    /// 04:48 and 03:30; the blend lands at ~04:09.
    public var estimatedCBTMin: ClockTime {
        let fromWake = habitualWake.adding(hours: -chronotype.cbtMinToWakeHours)
        let dlmo = habitualBedtime.adding(hours: -2.5)
        let fromDLMO = dlmo.adding(hours: 7)
        return ClockTime(hours: CircadianHours.interpolate(
            from: fromWake.hours, to: fromDLMO.hours, fraction: 0.5
        ))
    }

    /// Multiplier applied to every predicted phase shift, capturing the reduced
    /// circadian light sensitivity seen in older adults.
    ///
    /// Flat below 40, then a gentle decline to a floor of 0.65 — a deliberately
    /// conservative reading of a literature that reports blunting without a single
    /// agreed dose–age function.
    public var lightSensitivity: Double {
        guard age > 40 else { return 1.0 }
        return max(0.65, 1.0 - Double(age - 40) * 0.008)
    }
}
