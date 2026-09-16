#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import LuminaLayout
import LuminaIPC

public final class AXObserverHub {
    private var observers: [pid_t: AXObserver] = [:]
    public var onNotification: ((pid_t, String, AXUIElement) -> Void)?

    public func watch(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let err = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            var owner: pid_t = 0
            AXUIElementGetPid(element, &owner)
            hub.onNotification?(owner, name, element)
        }, &observer)
        guard err == .success, let observer else { return }
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXApplicationHiddenNotification,
        ]
        let app = AXUIElementCreateApplication(pid)
        for n in notifications {
            AXObserverAddNotification(observer, app, n as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    public func unwatch(pid: pid_t) {
        observers[pid] = nil
    }
}
#endif
