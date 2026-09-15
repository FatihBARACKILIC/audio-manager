import Foundation
import ServiceManagement

/// Launch-at-login, through the only supported API.
///
/// `SMAppService` asks the system to register the app bundle itself; we never write a
/// launch agent plist by hand, which is both unsupported and a common way to leave
/// stale entries behind after an uninstall.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Brings the system state in line with the user's preference.
    /// Returns the state actually achieved, which may differ if the user denied it in
    /// System Settings.
    @discardableResult
    static func synchronize(enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The user can also flip this in System Settings; reporting the real state
            // back is more useful than surfacing an error they cannot act on.
            return isEnabled
        }
        return isEnabled
    }
}
