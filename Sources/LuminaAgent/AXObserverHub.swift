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
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.watch(pid: pid) }
            return
        }
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
        let app = AXUIElementCreateApplication(pid)
        let appNotes = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationHiddenNotification,
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in appNotes {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    public func watchWindow(_ element: AXUIElement, pid: pid_t) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.watchWindow(element, pid: pid) }
            return
        }
        watch(pid: pid)
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let windowNotes = [
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification,
        ]
        for n in windowNotes {
            AXObserverAddNotification(observer, element, n as CFString, refcon)
        }
    }

    public func unwatch(pid: pid_t) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.unwatch(pid: pid) }
            return
        }
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
#endif
