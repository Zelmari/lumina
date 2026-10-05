import Foundation

public struct TitleBarSwapProbe: Equatable, Sendable {
    public var pasteboardChanged: Bool
    public var displacement: Double
    public var pointerOverTile: Bool
    public var mouseButtonsDown: Bool
    public var generationInFlight: Bool

    public init(
        pasteboardChanged: Bool,
        displacement: Double,
        pointerOverTile: Bool,
        mouseButtonsDown: Bool = false,
        generationInFlight: Bool = false
    ) {
        self.pasteboardChanged = pasteboardChanged
        self.displacement = displacement
        self.pointerOverTile = pointerOverTile
        self.mouseButtonsDown = mouseButtonsDown
        self.generationInFlight = generationInFlight
    }
}

public func shouldTitleBarSwap(_ probe: TitleBarSwapProbe) -> Bool {
    if probe.pasteboardChanged { return false }
    if probe.displacement < 20 { return false }
    if !probe.pointerOverTile { return false }
    if probe.mouseButtonsDown { return false }
    if probe.generationInFlight { return false }
    return true
}

public func shouldIgnoreFFM(mouseButtonsDown: Bool, generationInFlight: Bool) -> Bool {
    mouseButtonsDown || generationInFlight
}

/// Following the activated app's window to another space is for a deliberate
/// app switch. The OS also activates a new frontmost app when a window closes,
/// which must not drag the user off the workspace they are on. An empty
/// workspace is a valid place to be, and a just-performed switch must settle.
public func shouldFollowAppActivation(
    spaceHasWindows: Bool,
    elapsedSinceSpaceChange: TimeInterval,
    followDelay: TimeInterval = 0.8
) -> Bool {
    spaceHasWindows && elapsedSinceSpaceChange > followDelay
}

public func shouldIgnoreAXGeometry(windowGeneration: UInt64, inFlight: UInt64?) -> Bool {
    guard let inFlight else { return false }
    return windowGeneration == inFlight
}

/// Whether a window we pre-parked should be put back after the app moved it.
/// Never fight the user (a drag or a copy changes the pasteboard) and never
/// re-issue while our own write is still settling; bounded attempts stop an
/// app that re-centers endlessly from looping.
public func shouldRePark(
    mouseDown: Bool,
    pasteboardChanged: Bool,
    generationInFlight: Bool,
    attempts: Int,
    maxAttempts: Int
) -> Bool {
    if mouseDown { return false }
    if pasteboardChanged { return false }
    if generationInFlight { return false }
    return attempts < maxAttempts
}

public struct MiniaturizeEvent: Equatable, Sendable {
    public var tagged: Bool
    public init(tagged: Bool) { self.tagged = tagged }
}

public enum MiniaturizeAction: Equatable, Sendable {
    case ignore
    case deminiaturize
}

public func onMiniaturize(_ event: MiniaturizeEvent) -> MiniaturizeAction {
    event.tagged ? .ignore : .deminiaturize
}

public struct LayoutCoalesce: Equatable, Sendable {
    public var pending: Bool
    public init(pending: Bool = false) { self.pending = pending }
    public mutating func schedule() { pending = true }
    public mutating func drain() -> Bool {
        let had = pending
        pending = false
        return had
    }
}

public func shouldSkipRemainingWindows(elapsed: TimeInterval, budget: TimeInterval = 0.2) -> Bool {
    elapsed > budget
}

public enum PauseReason: Equatable, Sendable {
    case none
    case user
    case displayGone
    case axDenied
}

public func shouldAutoResume(userPaused: Bool, boundUUID: String, availableUUIDs: [String]) -> Bool {
    if userPaused { return false }
    return availableUUIDs.contains(boundUUID)
}

public func shouldStayPausedForDisplay(boundUUID: String, availableUUIDs: [String]) -> Bool {
    !availableUUIDs.contains(boundUUID)
}
