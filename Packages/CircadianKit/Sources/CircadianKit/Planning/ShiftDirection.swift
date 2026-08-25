import Foundation

/// Which way the pacemaker has to move.
public enum ShiftDirection: String, Sendable, Codable, Hashable {
    /// Clock moves earlier. Needed for eastward travel; the harder direction.
    case advance
    /// Clock moves later. Needed for westward travel; easier, because the intrinsic
    /// period is slightly longer than 24 h.
    case delay
    /// No meaningful shift required.
    case none

    public var opposite: ShiftDirection {
        switch self {
        case .advance: .delay
        case .delay: .advance
        case .none: .none
        }
    }

    /// Sign to multiply an hour magnitude by to get a signed shift.
    public var sign: Double {
        switch self {
        case .advance: 1
        case .delay: -1
        case .none: 0
        }
    }

    public init(signedShift: Double, threshold: Double = 0.5) {
        if abs(signedShift) < threshold { self = .none }
        else if signedShift > 0 { self = .advance }
        else { self = .delay }
    }

    public var displayName: String {
        switch self {
        case .advance: "Advance"
        case .delay: "Delay"
        case .none: "No shift"
        }
    }

    public var travelDescription: String {
        switch self {
        case .advance: "shifting earlier, as eastward travel needs"
        case .delay: "shifting later, as westward travel needs"
        case .none: "staying on your current schedule"
        }
    }
}
