// How a battery reading should be shown. Kept free of SwiftUI so it can be tested.
import Foundation

enum BatteryLevel: Equatable {
    case charging
    case critical   // red
    case low        // orange
    case normal     // no colour of its own

    /// macOS turns the battery red at 20% and shows charging in green; the orange step in
    /// between is a warning you can still act on before it matters.
    static func of(percent: Int, charging: Bool) -> BatteryLevel {
        if charging { return .charging }
        if percent <= 20 { return .critical }
        if percent <= 35 { return .low }
        return .normal
    }

    /// The glyph for the reading, matching the system's battery symbols.
    static func symbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
