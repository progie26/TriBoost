import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService`. No helper tool, no login item plist.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the change stuck, so the UI can stay honest if macOS
    /// refused (which it does for apps that are not in /Applications).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("TriBoost: launch at login \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
