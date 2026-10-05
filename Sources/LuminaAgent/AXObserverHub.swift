#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import LuminaLayout
import LuminaIPC

public final class AXObserverHub: @unchecked Sendable {
    private var observers: [pid_t: AXObserver] = [:]
    /// Window elements with registered notifications, per pid, so they can be
    /// unregistered when a window is destroyed or its app exits. Without this
    /// the five notes added per window accumulate for the observer's lifetime.
    private var watchedWindows: [pid_t: [AXUIElement]] = [:]
    public var onNotification: ((pid_t, String, AXUIElement) -> Void)?

    private static let windowNotes = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
    ]

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
            if name == kAXUIElementDestroyedNotification {
                hub.unwatchWindow(element, pid: owner)
            }
            hub.onNotification?(owner, name, element)
        }, &observer)
        guard err == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let appNotes = [
            kAXWindowCreatedNotification,
            // Generic element creation. It arrives before the window-specific
            // note for some apps and is what yabai uses as its primary signal;
            // the handler filters it down to window elements cheaply.
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationHiddenNotification,
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in appNotes {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        // .commonModes, not .defaultMode: a window can be created while the
        // main run loop is in a tracking/modal mode (menu open, drag), and
        // .defaultMode defers the note until that mode ends.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    public func watchWindow(_ element: AXUIElement, pid: pid_t) {
        if !Thread.isMainThread {
            // AXUIElement is not Sendable; hand the main queue a retained pointer.
            nonisolated(unsafe) let token = Unmanaged.passRetained(element).toOpaque()
            DispatchQueue.main.async { [weak self] in
                let element = Unmanaged<AXUIElement>.fromOpaque(token).takeRetainedValue()
                self?.watchWindow(element, pid: pid)
            }
            return
        }
        watch(pid: pid)
        guard let observer = observers[pid] else { return }
        guard watchedWindows[pid]?.contains(where: { CFEqual($0, element) }) != true else { return }
        watchedWindows[pid, default: []].append(element)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotes {
            AXObserverAddNotification(observer, element, n as CFString, refcon)
        }
    }

    /// Remove every window notification registered for `element` and stop
    /// tracking it. Called when the element reports that it was destroyed.
    private func unwatchWindow(_ element: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        for n in Self.windowNotes {
            AXObserverRemoveNotification(observer, element, n as CFString)
        }
        watchedWindows[pid]?.removeAll { CFEqual($0, element) }
        if watchedWindows[pid]?.isEmpty == true { watchedWindows[pid] = nil }
    }

    /// Stop watching `element` even when it never sent a destroyed
    /// notification (rebinds and model-side removals). Hops to main, where
    /// the observer run-loop source and `watchedWindows` are owned.
    public func forgetWindow(_ element: AXUIElement) {
        if !Thread.isMainThread {
            nonisolated(unsafe) let token = Unmanaged.passRetained(element).toOpaque()
            DispatchQueue.main.async { [weak self] in
                let element = Unmanaged<AXUIElement>.fromOpaque(token).takeRetainedValue()
                self?.forgetWindow(element)
            }
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        unwatchWindow(element, pid: pid)
    }

    public func unwatch(pid: pid_t) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.unwatch(pid: pid) }
            return
        }
        // Releasing the observer drops its registrations; do not message a
        // terminated app to remove each window note.
        watchedWindows[pid] = nil
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
#endif
