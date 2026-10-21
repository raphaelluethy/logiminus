import Foundation
import ServiceManagement

/// "Open at Login" via SMAppService (the app must live in /Applications or ~/Applications).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "needs approval in System Settings → General → Login Items"
        case .notRegistered: return "off"
        case .notFound: return "unavailable (run the installed app)"
        @unknown default: return "unknown"
        }
    }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
