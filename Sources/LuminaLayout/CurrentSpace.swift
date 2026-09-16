import Foundation

public enum CurrentReason: String, Equatable, Sendable {
    case spaceChange
    case wake
    case stash
    case start
    case other
}

/// Design §5 order 1–5. SkyLight ids are optional; public path must work alone.
public func recomputeCurrent(
    reason: CurrentReason,
    skyLightCurrent: UInt64?,
    skyLightSelf: UInt64?,
    skyLightOthers: [UInt64],
    hasLargeOnScreen: Bool,
    isLastCurrent: Bool,
    otherClaims: Bool
) -> Bool {
    var current = false
    if let cur = skyLightCurrent, let selfId = skyLightSelf, cur == selfId {
        current = true
    } else if let cur = skyLightCurrent, skyLightOthers.contains(cur) {
        current = false
    } else if hasLargeOnScreen {
        current = true
    } else {
        switch reason {
        case .spaceChange:
            current = false
        case .start:
            current = true
        case .wake, .stash, .other:
            current = isLastCurrent
        }
    }
    if current && otherClaims && !isLastCurrent {
        return false
    }
    return current
}

public func isLargeOnScreen(width: Double, height: Double) -> Bool {
    width >= 8 && height >= 8
}

/// Slivers do not qualify for "current" via the large-window test, but do qualify for attach.
public func shouldAttach(hasAnyOnScreenIncludingSlivers: Bool) -> Bool {
    hasAnyOnScreenIncludingSlivers
}

public struct AgentPresence: Equatable, Sendable {
    public var instanceId: UUID
    public var isCurrent: Bool
    public var hasOnScreenIncludingSlivers: Bool

    public init(instanceId: UUID, isCurrent: Bool, hasOnScreenIncludingSlivers: Bool) {
        self.instanceId = instanceId
        self.isCurrent = isCurrent
        self.hasOnScreenIncludingSlivers = hasOnScreenIncludingSlivers
    }
}

public enum StartAttachDecision: Equatable, Sendable {
    case alreadyCurrent(UUID)
    case attach(UUID)
    case spawn
}

/// Extra `start`: current wins; else any on-screen window including slivers attaches;
/// two slivered agents → `lastCurrent` wins; else spawn.
public func startAttachDecision(agents: [AgentPresence], lastCurrent: UUID?) -> StartAttachDecision {
    let currents = agents.filter(\.isCurrent)
    if !currents.isEmpty {
        if let lastCurrent, currents.contains(where: { $0.instanceId == lastCurrent }) {
            return .alreadyCurrent(lastCurrent)
        }
        return .alreadyCurrent(currents[0].instanceId)
    }
    let slivered = agents.filter(\.hasOnScreenIncludingSlivers)
    if slivered.isEmpty { return .spawn }
    if let lastCurrent, slivered.contains(where: { $0.instanceId == lastCurrent }) {
        return .attach(lastCurrent)
    }
    return .attach(slivered[0].instanceId)
}

public func pickCurrentAgent(claimants: [UUID], lastCurrent: UUID?) -> UUID? {
    if let lastCurrent, claimants.contains(lastCurrent) { return lastCurrent }
    return claimants.first
}

public func shouldRegisterHotkeys(isCurrent: Bool, paused: Bool) -> Bool {
    isCurrent && !paused
}

public func usableRect(axVisibleFrame: Rect, outerGap: Int) -> Rect {
    axVisibleFrame.inset(by: Double(outerGap))
}

public func usableIsWide(_ usable: Rect) -> Bool {
    usable.w >= usable.h
}

/// AppKit `visibleFrame` is bottom-left Y-up. AX is top-left Y-down relative to the menu-bar display.
/// `menuBarScreenMaxY` is `NSScreen.screens[0].frame.maxY` (not `NSScreen.main`).
public func axRect(fromAppKit rect: Rect, menuBarScreenMaxY: Double) -> Rect {
    Rect(
        x: rect.x,
        y: menuBarScreenMaxY - rect.y - rect.h,
        w: rect.w,
        h: rect.h
    )
}

public func appKitRect(fromAX rect: Rect, menuBarScreenMaxY: Double) -> Rect {
    Rect(
        x: rect.x,
        y: menuBarScreenMaxY - rect.y - rect.h,
        w: rect.w,
        h: rect.h
    )
}
