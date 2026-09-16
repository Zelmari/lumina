#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import LuminaLayout
import LuminaIPC

@_silgen_name("_AXUIElementGetWindow")
func AXUIElementGetWindow_private(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> Int32

public enum SetFrameResult: Equatable, Sendable {
    case ok
    case failed
}

public final class AXAdapter {
    private var inFlight: [UInt32: UInt64] = [:]
    private var loggedMissingPrivateAPI = false
    private let log: LuminaLog
    public var menuBarScreenMaxY: Double = 0

    public init(log: LuminaLog) {
        self.log = log
    }

    public func setSystemTimeout() {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
    }

    public func windowId(for element: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        let err = AXUIElementGetWindow_private(element, &id)
        if err == 0, id != 0 {
            return id
        }
        if err != 0 && !loggedMissingPrivateAPI {
            loggedMissingPrivateAPI = true
            log.info("private _AXUIElementGetWindow missing or failed; using fallback matcher")
        }
        return fallbackWindowId(for: element)
    }

    private func fallbackWindowId(for element: AXUIElement) -> UInt32? {
        guard let frame = frame(of: element), let pid = pid(of: element) else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = info.filter { row in
            let owner = row[kCGWindowOwnerPID as String] as? pid_t
            guard owner == pid else { return false }
            guard let bounds = row[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let x = Double(bounds["X"] ?? 0)
            let y = Double(bounds["Y"] ?? 0)
            let w = Double(bounds["Width"] ?? 0)
            let h = Double(bounds["Height"] ?? 0)
            return abs(x - frame.x) < 2 && abs(y - frame.y) < 2 && abs(w - frame.w) < 2 && abs(h - frame.h) < 2
        }
        if matches.count == 1 {
            return matches[0][kCGWindowNumber as String] as? UInt32
        }
        return nil
    }

    public func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(element, &pid)
        return err == .success ? pid : nil
    }

    public func frame(of element: AXUIElement) -> Rect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return Rect(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }

    public func setFrame(_ rect: Rect, of element: AXUIElement, tag window: inout WindowRef) -> SetFrameResult {
        window.generation += 1
        inFlight[window.cgWindowId] = window.generation
        let ok = applyFrame(rect, of: element)
        if !ok {
            let retry = applyFrame(rect, of: element)
            inFlight[window.cgWindowId] = nil
            return retry ? .ok : .failed
        }
        inFlight[window.cgWindowId] = nil
        return .ok
    }

    public func shouldIgnoreAXGeometry(window: WindowRef) -> Bool {
        shouldIgnoreAXGeometry(windowGeneration: window.generation, inFlight: inFlight[window.cgWindowId])
    }

    public func generationInFlight(for id: UInt32) -> Bool {
        inFlight[id] != nil
    }

    private func applyFrame(_ rect: Rect, of element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var size = CGSize(width: rect.w, height: rect.h)
        var point = CGPoint(x: rect.x, y: rect.y)
        guard let sizeVal = AXValueCreate(.cgSize, &size),
              let posVal = AXValueCreate(.cgPoint, &point)
        else { return false }
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        guard let read = frame(of: element) else { return false }
        return abs(read.x - rect.x) < 4 && abs(read.y - rect.y) < 4
            && abs(read.w - rect.w) < 8 && abs(read.h - rect.h) < 8
    }

    public func pressClose(of element: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let button = ref, CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    public func isMinimized(_ element: AXUIElement) -> Bool {
        boolAttribute(element, kAXMinimizedAttribute as CFString)
    }

    public func deminiaturize(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    public func unhide(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
        }
    }

    public func hasZoomButton(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &ref)
        return err == .success && ref != nil && CFGetTypeID(ref!) == AXUIElementGetTypeID()
    }

    public func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as CFString)
    }

    public func subrole(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXSubroleAttribute as CFString)
    }

    public func title(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXTitleAttribute as CFString)
    }

    public func bundleId(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func isFullscreen(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let attr = "AXFullScreen" as CFString
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    public func setFullscreen(_ element: AXUIElement, _ value: Bool) {
        let attr = "AXFullScreen" as CFString
        AXUIElementSetAttributeValue(element, attr, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    public func setFocused(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    public func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement]
        else { return [] }
        return array
    }

    public func axWindow(pid: pid_t, cgWindowId: UInt32) -> AXUIElement? {
        windows(pid: pid).first { windowId(for: $0) == cgWindowId }
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success else { return nil }
        return ref as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }
}

public struct BoundDisplay {
    public var uuid: String
    public var nsScreen: NSScreen
    public var axFrame: Rect
    public var axVisibleFrame: Rect

    public func usableRect(gaps: Gaps) -> Rect {
        usableRect(axVisibleFrame: axVisibleFrame, outerGap: gaps.outer)
    }

    public static func resolve(menuBarMaxY: Double, focusedCenter: Point?) -> BoundDisplay? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let picked: NSScreen
        if let focusedCenter {
            picked = screens.first(where: { screen in
                let ax = axRect(fromAppKit: nsRect(screen.frame), menuBarScreenMaxY: menuBarMaxY)
                return ax.contains(point: focusedCenter)
            }) ?? NSScreen.main ?? screens[0]
        } else {
            picked = NSScreen.main ?? screens[0]
        }
        return from(screen: picked, menuBarMaxY: menuBarMaxY)
    }

    public static func from(screen: NSScreen, menuBarMaxY: Double) -> BoundDisplay? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let number else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(number).takeRetainedValue()
        let uuidString = CFUUIDCreateString(nil, uuid) as String
        return BoundDisplay(
            uuid: uuidString,
            nsScreen: screen,
            axFrame: axRect(fromAppKit: nsRect(screen.frame), menuBarScreenMaxY: menuBarMaxY),
            axVisibleFrame: axRect(fromAppKit: nsRect(screen.visibleFrame), menuBarScreenMaxY: menuBarMaxY)
        )
    }
}

func nsRect(_ r: NSRect) -> Rect {
    Rect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
}

func menuBarMaxY() -> Double {
    Double(NSScreen.screens.first?.frame.maxY ?? 0)
}

func onScreenCGWindows(intersecting axFrame: Rect) -> [[String: Any]] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.filter { row in
        guard let bounds = row[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        let rect = Rect(
            x: Double(bounds["X"] ?? 0),
            y: Double(bounds["Y"] ?? 0),
            w: Double(bounds["Width"] ?? 0),
            h: Double(bounds["Height"] ?? 0)
        )
        return rect.intersects(axFrame)
    }
}

public func classifyInput(
    from element: AXUIElement,
    adapter: AXAdapter,
    bound: BoundDisplay,
    onScreenIds: Set<UInt32>
) -> (ClassifyInput, UInt32, pid_t)? {
    guard let id = adapter.windowId(for: element), id != 0 else { return nil }
    guard let pid = adapter.pid(of: element) else { return nil }
    let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
    let pidHasOnScreen = onScreenIds.contains { other in
        other != id && onScreenCGWindows(intersecting: bound.axFrame).contains { row in
            (row[kCGWindowNumber as String] as? UInt32) == other
                && (row[kCGWindowOwnerPID as String] as? pid_t) == pid
        }
    }
    let layer = (onScreenCGWindows(intersecting: bound.axFrame).first { ($0[kCGWindowNumber as String] as? UInt32) == id }?[kCGWindowLayer as String] as? Int) ?? 0
    let input = ClassifyInput(
        bundleId: adapter.bundleId(pid: pid),
        title: adapter.title(of: element),
        role: adapter.role(of: element),
        subrole: adapter.subrole(of: element),
        hasZoomButton: adapter.hasZoomButton(element),
        width: frame.w,
        height: frame.h,
        isOnScreen: onScreenIds.contains(id) && frame.w >= 8 && frame.h >= 8,
        pidAlreadyHasOnScreenWindow: pidHasOnScreen,
        layerOrIsHUD: layer > 0,
        isPiP: adapter.subrole(of: element) == "AXPictureInPictureWindow",
        isVisualIntelligenceOrSiriHUD: false,
        centerOnBoundDisplay: centerOnDisplay(rect: frame, displayFrame: bound.axFrame)
    )
    return (input, id, pid)
}
#endif
