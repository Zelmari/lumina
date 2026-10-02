#if os(macOS)
import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC

/// Why a tile frame did not land. Collapsing these into one `failed` made every
/// transient AX timeout look like an app that refuses to be tiled, which then
/// got permanently demoted to floating.
public enum SetFrameResult: Equatable, Sendable {
    case ok
    /// AX explicitly rejected the write (dead element, API disabled, illegal arg).
    /// Carries the raw `AXError` so stale elements can be told from refusals.
    case rejected(AXError)
    /// Writes reported success and reads were trustworthy, yet the frame still differs.
    /// This is the only result that is evidence the app is fighting the tile.
    case notLanded
    /// A write or read timed out. We do not know whether the frame landed.
    case unknown
}

/// `rejected` and `unknown` are both "no trustworthy evidence": they must never
/// float a window. Only `notLanded` may, and only after the retry deadline.
func failureIsEvidence(_ result: SetFrameResult) -> Bool {
    result == .notLanded
}

private func mergeWriteResults(_ a: SetFrameResult, _ b: SetFrameResult) -> SetFrameResult {
    if case .rejected = a { return a }
    if case .rejected = b { return b }
    if a == .unknown || b == .unknown { return .unknown }
    return .notLanded
}

/// Per-element AX writes must not fail just because an app is busy launching.
/// Reads use the same value because it is set on the window element.
private let axWriteTimeout: Float = 0.15

private enum AXWriteOutcome: Equatable {
    case accepted
    case rejected(AXError)
    case timedOut
}

private func classifyWrite(_ errors: [AXError]) -> AXWriteOutcome {
    let rejected: Set<AXError> = [.apiDisabled, .invalidUIElement, .illegalArgument, .attributeUnsupported, .notImplemented]
    if let first = errors.first(where: rejected.contains) { return .rejected(first) }
    if errors.contains(.cannotComplete) { return .timedOut }
    return .accepted
}

private typealias AXGetWindow = @convention(c) (CFTypeRef, UnsafeMutablePointer<UInt32>) -> Int32

/// `RTLD_DEFAULT` is `((void *)-2)`, which Swift cannot import.
nonisolated(unsafe) private let dlDefault = UnsafeMutableRawPointer(bitPattern: -2)

/// The `LuminaLayout` enum shadows the module, so the free function cannot be named here.
private func ignoreAXGeometry(windowGeneration: UInt64, inFlight: UInt64?) -> Bool {
    shouldIgnoreAXGeometry(windowGeneration: windowGeneration, inFlight: inFlight)
}

private let axGetWindow: AXGetWindow? = {
    guard let dlDefault, let sym = dlsym(dlDefault, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: AXGetWindow.self)
}()

public final class AXAdapter {
    private var inFlight: [UInt32: UInt64] = [:]
    private var idCache: [UInt: UInt32] = [:]
    private var minSizeCache: [UInt: Size] = [:]
    private var tracked: [UInt32: AXUIElement] = [:]
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

    public func windowId(for element: AXUIElement, excluding: Set<UInt32> = []) -> UInt32? {
        if let cached = cachedWindowId(for: element), !excluding.contains(cached) {
            return cached
        }
        if let axGetWindow {
            var id: UInt32 = 0
            let err = axGetWindow(element, &id)
            if err == 0, id != 0, !excluding.contains(id) {
                return id
            }
            if err != 0 && !loggedMissingPrivateAPI {
                loggedMissingPrivateAPI = true
                log.info("private _AXUIElementGetWindow failed err=\(err); using fallback matcher")
            }
        } else if !loggedMissingPrivateAPI {
            loggedMissingPrivateAPI = true
            log.info("private _AXUIElementGetWindow missing; using fallback matcher")
        }
        return fallbackWindowId(for: element, excluding: excluding)
    }

    public func cachedWindowId(for element: AXUIElement) -> UInt32? {
        let key = elementKey(element)
        if let cached = idCache[key] { return cached }
        for (id, el) in tracked where CFEqual(el, element) {
            idCache[key] = id
            return id
        }
        return nil
    }

    public func rememberWindowId(_ id: UInt32, for element: AXUIElement) {
        if let old = tracked.first(where: { CFEqual($0.value, element) && $0.key != id })?.key {
            tracked[old] = nil
            idCache = idCache.filter { $0.value != old }
        }
        idCache[elementKey(element)] = id
        tracked[id] = element
    }

    public func forgetWindowId(_ id: UInt32) {
        if let el = tracked[id] {
            minSizeCache[elementKey(el)] = nil
        }
        idCache = idCache.filter { $0.value != id }
        tracked[id] = nil
        inFlight[id] = nil
    }

    public func focusedWindow(of appOrWindow: AXUIElement) -> AXUIElement? {
        if role(of: appOrWindow) == "AXWindow" { return appOrWindow }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appOrWindow, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXUIElementGetTypeID()
        else { return nil }
        return (val as! AXUIElement)
    }

    private func elementKey(_ element: AXUIElement) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(element as AnyObject).toOpaque())
    }

    private func fallbackWindowId(for element: AXUIElement, excluding: Set<UInt32>) -> UInt32? {
        guard let frame = frame(of: element), let pid = pid(of: element) else { return nil }
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var owned: [(id: UInt32, frame: Rect)] = []
        for row in info {
            guard cgOwnerPID(row) == pid, let id = cgWindowID(row) else { continue }
            guard let rect = cgWindowRect(row) else { continue }
            if cgWindowLayer(row) > 0 { continue }
            owned.append((id, rect))
        }
        return pickCGWindowId(axFrame: frame, candidates: owned, excluding: excluding)
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

    public func setFrame(_ rect: Rect, of element: AXUIElement, tag window: inout LuminaLayout.Window) -> SetFrameResult {
        window.generation += 1
        let id = window.cgWindowId
        let gen = window.generation
        inFlight[id] = gen
        let first = applyFrame(rect, of: element)
        var result = first
        if first != .ok {
            let second = applyFrame(rect, of: element)
            result = second == .ok ? .ok : mergeWriteResults(first, second)
        }
        scheduleInFlightClear(id: id, gen: gen)
        return result
    }

    private func scheduleInFlightClear(id: UInt32, gen: UInt64) {
        // AXMoved/AXResized arrive after we return; keep the tag until they can be ignored.
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.inFlight[id] == gen { self?.inFlight[id] = nil }
        }
    }

    public func shouldIgnoreAXGeometry(window: LuminaLayout.Window) -> Bool {
        ignoreAXGeometry(windowGeneration: window.generation, inFlight: inFlight[window.cgWindowId])
    }

    public func clearInFlight(id: UInt32, generation: UInt64) {
        if inFlight[id] == generation { inFlight[id] = nil }
    }

    public func generationInFlight(for id: UInt32) -> Bool {
        inFlight[id] != nil
    }

    public func setStashFrame(_ rect: Rect, of element: AXUIElement, tag window: inout LuminaLayout.Window) -> SetFrameResult {
        window.generation += 1
        let id = window.cgWindowId
        let gen = window.generation
        inFlight[id] = gen
        let result = applyStashFrame(rect, of: element)
        scheduleInFlightClear(id: id, gen: gen)
        return result
    }

    /// Position first, then shrink. Size-first would collapse the tile in-place;
    /// origin-past-the-display is clamped back onto the desktop.
    private func applyStashFrame(_ rect: Rect, of element: AXUIElement) -> SetFrameResult {
        AXUIElementSetMessagingTimeout(element, axWriteTimeout)
        var size = CGSize(width: rect.w, height: rect.h)
        var point = CGPoint(x: rect.x, y: rect.y)
        guard let sizeVal = AXValueCreate(.cgSize, &size),
              let posVal = AXValueCreate(.cgPoint, &point)
        else { return .rejected(.illegalArgument) }
        let pos1 = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        let s1 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        let pos2 = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        let s2 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        let errors = [pos1, s1, pos2, s2]
        switch classifyWrite(errors) {
        case .rejected(let err):
            logWriteFailure("stash", err: err, errors: errors)
            return .rejected(err)
        case .timedOut:
            return .unknown
        case .accepted:
            guard let got = frame(of: element) else { return .unknown }
            return framesClose(got, rect) ? .ok : .notLanded
        }
    }

    private func applyFrame(_ rect: Rect, of element: AXUIElement) -> SetFrameResult {
        AXUIElementSetMessagingTimeout(element, axWriteTimeout)
        func write() -> AXWriteOutcome {
            var size = CGSize(width: rect.w, height: rect.h)
            var point = CGPoint(x: rect.x, y: rect.y)
            guard let sizeVal = AXValueCreate(.cgSize, &size),
                  let posVal = AXValueCreate(.cgPoint, &point)
            else { return .rejected(.illegalArgument) }
            let s1 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
            let pos = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
            let s2 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
            let errors = [s1, pos, s2]
            let outcome = classifyWrite(errors)
            if case .rejected(let err) = outcome {
                logWriteFailure("frame", err: err, errors: errors)
            }
            return outcome
        }
        let first = write()
        if case .rejected(let err) = first { return .rejected(err) }
        let afterFirst = frame(of: element)
        if let afterFirst, framesClose(afterFirst, rect) { return .ok }
        let second = write()
        if case .rejected(let err) = second { return .rejected(err) }
        let afterSecond = frame(of: element)
        if let afterSecond, framesClose(afterSecond, rect) { return .ok }
        // Writes were accepted and at least one read was trustworthy: the app
        // saw the request and did not honor it. That is the only evidence.
        if first == .accepted, second == .accepted, afterSecond != nil { return .notLanded }
        return .unknown
    }

    /// Raw codes so a stale element (`.invalidUIElement`) can be told apart
    /// from an app that refuses the attributes (`.attributeUnsupported`).
    private func logWriteFailure(_ kind: String, err: AXError, errors: [AXError]) {
        log.info("ax \(kind) write rejected err=\(err.rawValue) codes=[\(errors.map(\.rawValue).map(String.init).joined(separator: ","))]")
    }

    private func framesClose(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.w - b.w) <= 2 && abs(a.h - b.h) <= 2
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

    public func setFocused(_ element: AXUIElement, raise: Bool = false) {
        if raise {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    public func minSize(of element: AXUIElement) -> Size {
        let key = elementKey(element)
        if let cached = minSizeCache[key] { return cached }
        var ref: CFTypeRef?
        let attr = "AXMinSize" as CFString
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXValueGetTypeID()
        else { return .unknown }
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        let measured = Size(w: Double(size.width), h: Double(size.height))
        if measured != .unknown { minSizeCache[key] = measured }
        return measured
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
        axVisibleFrame.inset(by: Double(gaps.outer))
    }

    public static func resolve(menuBarMaxY: Double, focusedCenter: Point?, preferredUUID: String? = nil) -> BoundDisplay? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let preferredUUID,
           let match = screens.compactMap({ from(screen: $0, menuBarMaxY: menuBarMaxY) }).first(where: { $0.uuid == preferredUUID })
        {
            return match
        }
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

func cgWindowID(_ row: [String: Any]) -> UInt32? {
    cgNSNumber(row[kCGWindowNumber as String])?.uint32Value
}

func cgOwnerPID(_ row: [String: Any]) -> pid_t? {
    cgNSNumber(row[kCGWindowOwnerPID as String])?.int32Value
}

func cgWindowLayer(_ row: [String: Any]) -> Int {
    cgNSNumber(row[kCGWindowLayer as String])?.intValue ?? 0
}

func cgWindowRect(_ row: [String: Any]) -> Rect? {
    guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return Rect(
        x: cgNSNumber(bounds["X"])?.doubleValue ?? 0,
        y: cgNSNumber(bounds["Y"])?.doubleValue ?? 0,
        w: cgNSNumber(bounds["Width"])?.doubleValue ?? 0,
        h: cgNSNumber(bounds["Height"])?.doubleValue ?? 0
    )
}

private func cgNSNumber(_ value: Any?) -> NSNumber? {
    if let n = value as? NSNumber { return n }
    if let i = value as? Int { return NSNumber(value: i) }
    if let d = value as? Double { return NSNumber(value: d) }
    if let f = value as? CGFloat { return NSNumber(value: Double(f)) }
    return nil
}

func cgWindowRect(id: UInt32) -> Rect? {
    let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return info.first { cgWindowID($0) == id }.flatMap(cgWindowRect)
}

func onScreenCGWindows(intersecting axFrame: Rect) -> [[String: Any]] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return info.filter { row in
        guard let rect = cgWindowRect(row) else { return false }
        return rect.intersects(axFrame)
    }
}

public func classifyInput(
    from element: AXUIElement,
    adapter: AXAdapter,
    bound: BoundDisplay,
    onScreenIds: Set<UInt32>,
    excludingWindowIds: Set<UInt32> = []
) -> (ClassifyInput, UInt32, pid_t)? {
    guard let pid = adapter.pid(of: element) else { return nil }
    let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
    guard let id = adapter.windowId(for: element, excluding: excludingWindowIds), id != 0 else { return nil }
    let onScreenRows = onScreenCGWindows(intersecting: bound.axFrame)
    let pidOnScreenFrames: [Rect] = onScreenRows.compactMap { row in
        guard cgOwnerPID(row) == pid, let rect = cgWindowRect(row), rect.w >= 8, rect.h >= 8 else { return nil }
        return rect
    }
    let idOnScreen = onScreenIds.contains(id)
    let layer = cgWindowLayer(onScreenRows.first { cgWindowID($0) == id } ?? [:])
    let screens = NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: adapter.menuBarScreenMaxY)?.axFrame }
    let bundle = adapter.bundleId(pid: pid)
    let input = ClassifyInput(
        bundleId: bundle,
        title: adapter.title(of: element),
        role: adapter.role(of: element),
        subrole: adapter.subrole(of: element),
        hasZoomButton: adapter.hasZoomButton(element),
        width: frame.w,
        height: frame.h,
        isOnScreen: idOnScreen,
        pidAlreadyHasOnScreenWindow: !pidOnScreenFrames.isEmpty,
        layerOrIsHUD: layer >= 3,
        isPiP: adapter.subrole(of: element) == "AXPictureInPictureWindow",
        isVisualIntelligenceOrSiriHUD: Classify.visualIntelligenceBundleIds.contains(bundle ?? ""),
        centerOnBoundDisplay: shouldManageOnBoundDisplay(rect: frame, bound: bound.axFrame, screens: screens)
    )
    return (input, id, pid)
}
#endif
