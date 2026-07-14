import ServiceManagement
import SwiftUI

/// Thin wrapper over `SMAppService.mainApp` so the app can register itself as a
/// login item without a helper bundle (macOS 13+).
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private init() {}

    var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("Hone: launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
