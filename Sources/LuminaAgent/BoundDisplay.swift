#if os(macOS)
import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC

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

#endif
