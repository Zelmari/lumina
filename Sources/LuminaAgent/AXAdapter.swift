#if os(macOS)
import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC

/// Why a setFrame call did not report success. This is for logging and
/// diagnostics only. No model state changes because of a write result; the
/// next declarative layout pass re-issues the frame.
public enum SetFrameResult: Equatable, Sendable {
    case ok
    /// AX explicitly rejected the write (dead element, API disabled, illegal arg).
    case rejected(AXError)
    /// A write timed out. We do not know whether the frame landed.
    case unknown
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
    private let lock = NSLock()
    private var inFlight: [UInt32: UInt64] = [:]
    private var idCache: [UInt: UInt32] = [:]
    private var minSizeCache: [UInt: Size] = [:]
    private var tracked: [UInt32: AXUIElement] = [:]
    private var loggedMissingPrivateAPI = false
    private var accessibilityWakeAt: [pid_t: Date] = [:]
    private var accessibilityHealthy: Set<pid_t> = []
    private var accessibilityDelivered: Set<pid_t> = []
    /// Application element and last observed AXEnhancedUserInterface value.
    /// Every frame write toggles that flag, and the prior value used to cost
    /// an application-element creation plus an attribute read per window.
    private var enhancedUICache: [pid_t: (app: AXUIElement, prior: Bool, at: Date)] = [:]
    private let enhancedUICacheTTL: TimeInterval = 2
    private let accessibilityWakeRetry: TimeInterval = 2
    private let log: LuminaLog
    public var menuBarScreenMaxY: Double = 0

    public init(log: LuminaLog) {
        self.log = log
    }

    public func setSystemTimeout() {
        // Do not set a 50ms system-wide timeout; busy apps time out AX calls with -25201.
        // Writes use axWriteTimeout (150ms) per element.
    }

    public func windowId(for element: AXUIElement, excluding: Set<UInt32> = []) -> UInt32? {
        if let cached = cachedWindowId(for: element) {
            // The element resolves to a known id. If that id is claimed by
            // another element, this is the same window seen twice, not a new
            // one: falling through to the frame matcher would mint a phantom
            // id for it (and adopt a chrome window as a tile).
            return excluding.contains(cached) ? nil : cached
        }
        if let axGetWindow {
            var id: UInt32 = 0
            let err = axGetWindow(element, &id)
            if err == 0, id != 0 {
                return excluding.contains(id) ? nil : id
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

    /// The window id only when it resolves without the frame-matching
    /// fallback. Used to filter generic AXCreated noise cheaply: a non-window
    /// element costs no AX server round trip here (the private id call and the
    /// cache are local).
    public func windowIdIfKnown(for element: AXUIElement) -> UInt32? {
        if let cached = cachedWindowId(for: element) { return cached }
        guard let axGetWindow else { return nil }
        var id: UInt32 = 0
        let err = axGetWindow(element, &id)
        return err == 0 && id != 0 ? id : nil
    }

    /// Pointer-keyed lookup. AXUIElement pointers are reused after the AX
    /// server destroys an element, so a cache hit is only trusted when the
    /// tracked element at that id is still the same object; otherwise the
    /// stale entries are dropped and the caller re-resolves.
    public func cachedWindowId(for element: AXUIElement) -> UInt32? {
        let key = elementKey(element)
        lock.lock()
        defer { lock.unlock() }
        if let cached = idCache[key] {
            if let trackedElement = tracked[cached], CFEqual(trackedElement, element) {
                return cached
            }
            idCache[key] = nil
            minSizeCache[key] = nil
        }
        for (id, el) in tracked where CFEqual(el, element) {
            idCache[key] = id
            return id
        }
        return nil
    }

    public func rememberWindowId(_ id: UInt32, for element: AXUIElement) {
        lock.lock()
        defer { lock.unlock() }
        if let old = tracked.first(where: { CFEqual($0.value, element) && $0.key != id })?.key {
            tracked[old] = nil
            idCache = idCache.filter { $0.value != old }
        }
        if let previous = tracked[id], !CFEqual(previous, element) {
            let key = elementKey(previous)
            idCache[key] = nil
            minSizeCache[key] = nil
        }
        idCache[elementKey(element)] = id
        tracked[id] = element
    }

    /// A destroyed window element can still answer `AXUIElementGetPid` while
    /// every attribute read/write fails with `.invalidUIElement`. Only an
    /// attribute read proves it is alive; other errors (timeouts, API
    /// disabled) are not proof of death.
    public func isLiveElement(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
        return err != .invalidUIElement
    }

    /// Strict proof of life: the role read succeeded. Used where a false
    /// "alive" would pin a model entry forever (removal veto); a timeout must
    /// not count as alive there.
    public func isAliveElement(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
        return err == .success
    }

    public func forgetWindowId(_ id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let el = tracked[id] {
            minSizeCache[elementKey(el)] = nil
        }
        idCache = idCache.filter { $0.value != id }
        tracked[id] = nil
        inFlight[id] = nil
    }

    /// Chromium/Electron keep their accessibility tree off until an assistive
    /// client asks. Set AXManualAccessibility (legacy builds: the private
    /// AXEnhancedUserInterface) to wake it. Asking before the app has a window
    /// can be a silent no-op, so the set is retried until the app accepts it;
    /// once accepted, never repeat it. Re-setting the flag while Chromium is
    /// building the tree keeps tearing it down, so AXWindows stays empty and
    /// the app's windows are never adopted.
    public func wakeAccessibility(pid: pid_t) {
        let now = Date()
        lock.lock()
        if accessibilityHealthy.contains(pid) || accessibilityDelivered.contains(pid) {
            lock.unlock()
            return
        }
        if let last = accessibilityWakeAt[pid], now.timeIntervalSince(last) < accessibilityWakeRetry {
            lock.unlock()
            return
        }
        accessibilityWakeAt[pid] = now
        lock.unlock()
        let app = AXUIElementCreateApplication(pid)
        let err = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if err == .success {
            lock.lock()
            accessibilityDelivered.insert(pid)
            lock.unlock()
            log.info("ax wake pid=\(pid) bundle=\(bundleId(pid: pid) ?? "?")")
        } else if err == .attributeUnsupported {
            // Legacy builds expose only the private AXEnhancedUserInterface flag.
            let legacyErr = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if legacyErr == .success {
                lock.lock()
                accessibilityDelivered.insert(pid)
                lock.unlock()
                log.info("ax wake legacy pid=\(pid) bundle=\(bundleId(pid: pid) ?? "?")")
            } else if legacyErr == .attributeUnsupported {
                // Neither attribute exists; the flag will never take. Do not retry.
                lock.lock()
                accessibilityDelivered.insert(pid)
                lock.unlock()
            }
        }
    }

    /// Once a window id resolves for the pid the tree is up; stop asking.
    public func markAccessibilityHealthy(pid: pid_t) {
        lock.lock()
        accessibilityHealthy.insert(pid)
        lock.unlock()
    }

    /// The app answered an AX window read with an empty list even though it
    /// has windows. Its accessibility tree was torn down after we marked it
    /// healthy; forget the wake state so the next resolve asks again. The
    /// wake timestamp is kept so `wakeAccessibility`'s retry throttle still
    /// applies: re-setting AXManualAccessibility while Chromium rebuilds the
    /// tree keeps tearing it down.
    public func markAccessibilityUnhealthy(pid: pid_t) {
        lock.lock()
        accessibilityHealthy.remove(pid)
        accessibilityDelivered.remove(pid)
        lock.unlock()
    }

    /// A terminated app must forget its wake state: a relaunch is a new pid.
    public func forgetAccessibility(pid: pid_t) {
        lock.lock()
        accessibilityWakeAt[pid] = nil
        accessibilityHealthy.remove(pid)
        accessibilityDelivered.remove(pid)
        enhancedUICache[pid] = nil
        lock.unlock()
    }

    public func focusedWindow(of appOrWindow: AXUIElement) -> AXUIElement? {
        if role(of: appOrWindow) == "AXWindow" { return appOrWindow }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appOrWindow, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let val = ref, CFGetTypeID(val) == AXUIElementGetTypeID() {
            return (val as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(appOrWindow, kAXMainWindowAttribute as CFString, &ref) == .success,
           let val = ref, CFGetTypeID(val) == AXUIElementGetTypeID() {
            return (val as! AXUIElement)
        }
        return nil
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
        lock.lock()
        inFlight[id] = gen
        lock.unlock()
        let result = applyFrame(rect, of: element)
        scheduleInFlightClear(id: id, gen: gen)
        return result
    }

    private func scheduleInFlightClear(id: UInt32, gen: UInt64) {
        // AXMoved/AXResized arrive after we return; keep the tag until they can be ignored.
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.inFlight[id] == gen { self.inFlight[id] = nil }
            self.lock.unlock()
        }
    }

    public func shouldIgnoreAXGeometry(window: LuminaLayout.Window) -> Bool {
        lock.lock()
        let inFlightGen = inFlight[window.cgWindowId]
        lock.unlock()
        return ignoreAXGeometry(windowGeneration: window.generation, inFlight: inFlightGen)
    }

    public func clearInFlight(id: UInt32, generation: UInt64) {
        lock.lock()
        if inFlight[id] == generation { inFlight[id] = nil }
        lock.unlock()
    }

    public func generationInFlight(for id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[id] != nil
    }

    /// Hide a window on an inactive space: move it only. Size is left alone so
    /// the app keeps its state and WindowServer is less likely to clamp the
    /// move. The next layout pass re-parks it if this did not land.
    public func setStashPosition(_ origin: Point, of element: AXUIElement, tag window: inout LuminaLayout.Window) -> SetFrameResult {
        window.generation += 1
        let id = window.cgWindowId
        let gen = window.generation
        lock.lock()
        inFlight[id] = gen
        lock.unlock()
        let result = applyStashPosition(origin, of: element)
        scheduleInFlightClear(id: id, gen: gen)
        return result
    }

    private func applyStashPosition(_ origin: Point, of element: AXUIElement) -> SetFrameResult {
        AXUIElementSetMessagingTimeout(element, axWriteTimeout)
        var point = CGPoint(x: origin.x, y: origin.y)
        guard let posVal = AXValueCreate(.cgPoint, &point) else { return .rejected(.illegalArgument) }
        let restore = disableAnimations(element)
        defer { restore() }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        let errors = [err]
        switch classifyWrite(errors) {
        case .rejected(let e):
            logWriteFailure("stash", err: e, errors: errors)
            return .rejected(e)
        case .timedOut:
            return .unknown
        case .accepted:
            return .ok
        }
    }

    private func applyFrame(_ rect: Rect, of element: AXUIElement) -> SetFrameResult {
        AXUIElementSetMessagingTimeout(element, axWriteTimeout)
        let restore = disableAnimations(element)
        defer { restore() }
        let errors = writeFrameValues(rect, of: element)
        let outcome = classifyWrite(errors)
        if case .rejected(let err) = outcome {
            logWriteFailure("frame", err: err, errors: errors)
        }
        switch outcome {
        case .accepted: return .ok
        case .rejected(let err): return .rejected(err)
        case .timedOut: return .unknown
        }
    }

    /// In macOS Accessibility, AXEnhancedUserInterface is an application-level attribute.
    /// When true, macOS forces animations on window moves and resizes. Setting it to false
    /// temporarily disables window animations so moves and resizes snap immediately.
    /// The application element and its prior value are cached briefly: a reflow
    /// writes many windows and must not pay an app creation plus an attribute
    /// read for each one.
    private func disableAnimations(_ element: AXUIElement) -> () -> Void {
        guard let pid = pid(of: element) else { return {} }
        let attr = "AXEnhancedUserInterface" as CFString
        let now = Date()
        lock.lock()
        let cached = enhancedUICache[pid]
        lock.unlock()
        let app: AXUIElement
        let prior: Bool
        if let cached, now.timeIntervalSince(cached.at) < enhancedUICacheTTL {
            app = cached.app
            prior = cached.prior
        } else {
            app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, axWriteTimeout)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attr, &ref) == .success else {
                // Restoring needs the prior value; without it, never disable the flag.
                return {}
            }
            prior = (ref as? Bool) ?? false
            lock.lock()
            enhancedUICache[pid] = (app, prior, now)
            lock.unlock()
        }
        AXUIElementSetAttributeValue(app, attr, kCFBooleanFalse)
        return {
            if prior == true {
                AXUIElementSetAttributeValue(app, attr, kCFBooleanTrue)
            }
        }
    }

    /// Writes size then position then size. The order matters: some apps clamp
    /// on resize, and re-applying the size after the move catches that.
    private func writeFrameValues(_ rect: Rect, of element: AXUIElement) -> [AXError] {
        var size = CGSize(width: rect.w, height: rect.h)
        var point = CGPoint(x: rect.x, y: rect.y)
        guard let sizeVal = AXValueCreate(.cgSize, &size),
              let posVal = AXValueCreate(.cgPoint, &point)
        else { return [.illegalArgument] }
        let s1 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        let pos = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        let s2 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        return [s1, pos, s2]
    }

    /// Raw codes so a stale element (`.invalidUIElement`) can be told apart
    /// from an app that refuses the attributes (`.attributeUnsupported`).
    private func logWriteFailure(_ kind: String, err: AXError, errors: [AXError]) {
        log.info("ax \(kind) write rejected err=\(err.rawValue) codes=[\(errors.map(\.rawValue).map(String.init).joined(separator: ","))]")
    }

    public func pressClose(of element: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let button = ref, CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// The green button. Native-fullscreen exit can leave the window zoomed
    /// to the screen, and `setFrame` is ignored until zoom is cleared.
    public func pressZoom(of element: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &ref) == .success,
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

    /// Best-effort hide, used by the launch shield before a window is visible.
    /// False means the app has not finished checking in or refuses to hide; the
    /// shield times out and reveals normally.
    @discardableResult
    public func hide(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.hide() ?? false
    }

    /// Bring an app forward after the shield reveals its window.
    public func activate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    public func hasZoomButton(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &ref) == .success,
           let btn = ref, CFGetTypeID(btn) == AXUIElementGetTypeID() {
            return true
        }
        if AXUIElementCopyAttributeValue(element, "AXFullScreenButton" as CFString, &ref) == .success,
           let btn = ref, CFGetTypeID(btn) == AXUIElementGetTypeID() {
            return true
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
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

    public func isAppHidden(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    // MARK: - Debug probe

    /// Attribute names exposed by an element, for the `debug-ax` probe.
    public func attributeNames(of element: AXUIElement) -> [String]? {
        var ref: CFArray?
        guard AXUIElementCopyAttributeNames(element, &ref) == .success,
              let names = ref as? [String]
        else { return nil }
        return names
    }

    public func children(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? [AXUIElement]
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static let debugTabAttributes = [
        "AXTabs", "AXSelectedChildren", "AXTabGroup", "AXMain", "AXFocused",
        "AXIdentifier", "AXDescription",
    ]

    /// A JSON view of an AX element and its children, focused on the
    /// attributes needed to detect native tab groups (`AXTabGroup`, `AXTabs`,
    /// `AXSelectedChildren`) and map tabs to windows.
    public func debugElementJSON(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 2) -> JSONValue {
        let names = attributeNames(of: element) ?? []
        var tabValues: [String: JSONValue] = [:]
        for name in Self.debugTabAttributes where names.contains(name) {
            tabValues[name] = copyAttribute(element, name).map { describeAXValue($0) } ?? .null
        }
        var object: [String: JSONValue] = [
            "role": .string(role(of: element) ?? ""),
            "subrole": .string(subrole(of: element) ?? ""),
            "title": .string(title(of: element) ?? ""),
            "attributeNames": .array(names.sorted().map { .string($0) }),
            "tabAttributes": .object(tabValues),
        ]
        if let id = windowId(for: element) { object["cgWindowId"] = .int(Int(id)) }
        if let frame = frame(of: element) {
            object["frame"] = .object([
                "x": .double(frame.x), "y": .double(frame.y),
                "w": .double(frame.w), "h": .double(frame.h),
            ])
        }
        if depth < maxDepth, let kids = children(of: element), !kids.isEmpty {
            object["children"] = .array(kids.prefix(24).map {
                debugElementJSON($0, depth: depth + 1, maxDepth: maxDepth)
            })
        }
        return .object(object)
    }

    private func describeAXValue(_ value: CFTypeRef) -> JSONValue {
        if let s = value as? String { return .string(s) }
        if let b = value as? Bool { return .bool(b) }
        if let n = value as? NSNumber { return .double(n.doubleValue) }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            return .object([
                "elementRole": .string(role(of: element) ?? "?"),
                "elementTitle": .string(title(of: element) ?? ""),
                "cgWindowId": windowId(for: element).map { .int(Int($0)) } ?? .null,
            ])
        }
        if let array = value as? [Any] {
            return .array(array.prefix(24).map { item -> JSONValue in
                let itemRef = item as CFTypeRef
                if CFGetTypeID(itemRef) == AXUIElementGetTypeID() {
                    return describeAXValue(itemRef)
                }
                return .string(String(describing: item))
            })
        }
        return .string(String(describing: type(of: value)))
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
            setMain(element)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Mark the window as the app's main window before raising, so activation
    /// brings the right window forward.
    public func setMain(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Apply native focus once: main, raise, activate. No retries or
    /// verification; the next activation notification re-drives focus.
    public func nativeFocus(_ element: AXUIElement, pid: pid_t) {
        setFocused(element, raise: true)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    public func minSize(of element: AXUIElement) -> Size {
        let key = elementKey(element)
        lock.lock()
        let cached = minSizeCache[key]
        lock.unlock()
        if let cached { return cached }
        var ref: CFTypeRef?
        let attr = "AXMinSize" as CFString
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXValueGetTypeID()
        else { return .unknown }
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        let measured = Size(w: Double(size.width), h: Double(size.height))
        if measured != .unknown {
            lock.lock()
            minSizeCache[key] = measured
            lock.unlock()
        }
        return measured
    }

    /// One app-wide window list. `.failed` means the read did not complete
    /// (timeout, cannotComplete, API disabled): the list is unknown, not
    /// empty. Callers deciding whether windows died must not treat it as `[]`.
    public enum WindowEnumeration {
        case list([AXUIElement])
        case failed
    }

    public func enumerateWindows(pid: pid_t) -> WindowEnumeration {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        guard err == .success, let array = ref as? [AXUIElement] else { return .failed }
        return .list(array)
    }

    public func windows(pid: pid_t) -> [AXUIElement] {
        if case .list(let array) = enumerateWindows(pid: pid) { return array }
        return []
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

#endif
