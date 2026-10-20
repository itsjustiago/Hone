import Foundation
import IOKit.ps

/// What currently powers the Mac, from the same Power Sources API the system's
/// battery menu uses. Needs no permission.
enum PowerSource: Equatable {
    case battery, ac, ups

    var title: String {
        switch self {
        case .battery: return "Bateria"
        case .ac: return "Corrente"
        case .ups: return "UPS"
        }
    }

    /// From the string `IOPSGetProvidingPowerSourceType` returns. Anything else is nil.
    init?(providingType type: String) {
        switch type {
        case kIOPMBatteryPowerKey, "Battery Power": self = .battery
        case kIOPMACPowerKey, "AC Power": self = .ac
        case kIOPMUPSPowerKey, "UPS Power": self = .ups
        default: return nil
        }
    }

    /// The providing source right now; nil when the system doesn't say.
    static func current() -> PowerSource? {
        // "Copy" hands over a +1 reference, "Get" a borrowed one tied to it.
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return PowerSource(providingType: type as String)
    }
}
