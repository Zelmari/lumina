#if os(macOS)
import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC

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
    onScreenRows: [[String: Any]]? = nil,
    excludingWindowIds: Set<UInt32> = []
) -> (ClassifyInput, UInt32, pid_t)? {
    guard let pid = adapter.pid(of: element) else { return nil }
    let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
    guard let id = adapter.windowId(for: element, excluding: excludingWindowIds), id != 0 else { return nil }
    // Callers that already enumerated the on-screen list for this pass pass it
    // in; re-enumerating is a WindowServer round trip per window.
    let rows = onScreenRows ?? onScreenCGWindows(intersecting: bound.axFrame)
    let pidOnScreenFrames: [Rect] = rows.compactMap { row in
        guard cgOwnerPID(row) == pid, let rect = cgWindowRect(row), rect.w >= 8, rect.h >= 8 else { return nil }
        return rect
    }
    let idOnScreen = onScreenIds.contains(id)
    let layer = cgWindowLayer(rows.first { cgWindowID($0) == id } ?? [:])
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
        isMinimized: adapter.isMinimized(element),
        pidAlreadyHasOnScreenWindow: !pidOnScreenFrames.isEmpty,
        layerOrIsHUD: layer >= 3,
        isPiP: adapter.subrole(of: element) == "AXPictureInPictureWindow",
        isVisualIntelligenceOrSiriHUD: Classify.visualIntelligenceBundleIds.contains(bundle ?? ""),
        centerOnBoundDisplay: shouldManageOnBoundDisplay(rect: frame, bound: bound.axFrame, screens: screens)
    )
    return (input, id, pid)
}

#endif
