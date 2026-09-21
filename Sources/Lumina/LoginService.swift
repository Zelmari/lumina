#if os(macOS)
import Foundation
import ServiceManagement

enum LoginService {
    /// Nil when the item is enabled or was removed. A string means Login Items still needs approval.
    static func toggle() -> String? {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                return nil
            }
            try service.register()
            if service.status == .requiresApproval {
                return "System Settings → Login Items must approve Lumina"
            }
            return nil
        } catch {
            return "System Settings → Login Items must approve Lumina"
        }
    }

    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
#endif
