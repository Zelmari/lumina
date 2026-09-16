#if os(macOS)
import Foundation
import ServiceManagement

enum LoginService {
    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // .requiresApproval surfaces in System Settings → Login Items
        }
    }

    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
#endif
