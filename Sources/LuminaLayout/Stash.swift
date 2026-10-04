import Foundation

public struct DisplayFrame: Equatable, Sendable {
    public var axFrame: Rect
    public var axVisibleFrame: Rect

    public init(axFrame: Rect, axVisibleFrame: Rect) {
        self.axFrame = axFrame
        self.axVisibleFrame = axVisibleFrame
    }
}

/// Park a window so only about `inset` points stay inside the visible rect.
/// Size is unchanged: macOS rejects a forced 1×N size, and a full-size window
/// whose origin sits on the bottom corner hangs off-screen (AeroSpace `hideInCorner`).
/// Dock on the right uses the bottom-left corner. `inset` is 0 for Zoom, which
/// jumps away from a 1px offset.
public func stashFrame(
    for lastHeight: Double,
    display: DisplayFrame,
    dockRight: Bool,
    lastWidth: Double = 1,
    inset: Double = 1
) -> Rect {
    let w = max(lastWidth, 1)
    let h = max(lastHeight, 1)
    let visible = display.axVisibleFrame
    let y = visible.maxY - inset
    let x = dockRight ? visible.minX + inset - w : visible.maxX - inset
    return Rect(x: x, y: y, w: w, h: h)
}

/// True when the window's origin is the bottom-corner park from `stashFrame`.
public func isCornerParked(_ rect: Rect, display: DisplayFrame) -> Bool {
    let visible = display.axVisibleFrame
    let onRight = abs(rect.minX - (visible.maxX - 1)) < 4 && rect.maxY > visible.maxY - 2
    let onLeft = abs(rect.maxX - (visible.minX + 1)) < 4 && rect.maxY > visible.maxY - 2 && rect.minX < visible.minX
    return onRight || onLeft
}

public func isSliver(_ rect: Rect) -> Bool {
    rect.w <= 2 || rect.h <= 2
}

public func isStashedOffDisplay(_ rect: Rect, display: DisplayFrame) -> Bool {
    rect.maxX <= display.axFrame.minX + 1 || rect.minX >= display.axFrame.maxX - 1
}

/// 1px strip on the top edge of the display. The rest hangs above the menu bar.
/// `inset` is that sliver, not the window height. A full-height `inset` pins the window on screen.
public func menuBarHangFrame(after: Rect, display: DisplayFrame, x: Double, inset: Double = 1) -> Rect {
    Rect(
        x: x,
        y: display.axFrame.minY - after.h + inset,
        w: after.w,
        h: after.h
    )
}

/// True when the window's bottom edge sits on the top of the display and the rest is above it.
public func isMenuBarParked(_ rect: Rect, display: DisplayFrame) -> Bool {
    let top = display.axFrame.minY
    return rect.minY < top && abs(rect.maxY - (top + 1)) < 4
}

/// Same as `isStashedAway`. The agent method of that name cannot call the free function.
public func isFrameStashedAway(_ rect: Rect, display: DisplayFrame) -> Bool {
    isStashedAway(rect, display: display)
}

/// Hidden workspace stash: sliver, corner park, menu-bar hang, past the display, or only in the chrome.
public func isStashedAway(_ rect: Rect, display: DisplayFrame) -> Bool {
    if isSliver(rect) { return true }
    if isCornerParked(rect, display: display) { return true }
    if isMenuBarParked(rect, display: display) { return true }
    if isStashedOffDisplay(rect, display: display) { return true }
    return display.axFrame.intersects(rect) && !display.axVisibleFrame.intersects(rect)
}

/// Save a frame as the on-screen tile only when it is actually on the desktop.
/// A second stash of an already parked window must not replace the tile rect.
public func shouldCaptureOnscreenFrame(role: WindowRole, frame: Rect, display: DisplayFrame) -> Bool {
    if role == .stashed { return false }
    if isStashedAway(frame, display: display) { return false }
    return display.axVisibleFrame.contains(point: frame.center)
}

public struct StashEntry: Equatable, Sendable, Codable {
    public var cgWindowId: UInt32
    public var pid: Int32
    public var bundleId: String?
    public var lastOnscreenFrame: Rect
    /// Pre-tiling frame, when known. Lets a fresh agent or a quit restore the
    /// user's own geometry instead of the last tile rect.
    public var originalFrame: Rect?

    public init(cgWindowId: UInt32, pid: Int32, bundleId: String?, lastOnscreenFrame: Rect, originalFrame: Rect? = nil) {
        self.cgWindowId = cgWindowId
        self.pid = pid
        self.bundleId = bundleId
        self.lastOnscreenFrame = lastOnscreenFrame
        self.originalFrame = originalFrame
    }
}

/// On-disk session. Does not persist paused, tree, ratios, or bookmarks.
/// `originals` is a global registry of pre-tiling geometry keyed by CGWindowID,
/// so a restart while windows are tiled (or drop+re-adopt churn) does not
/// permanently replace true originals with tile rects.
public struct SessionFile: Equatable, Sendable, Codable {
    public var instanceId: UUID
    public var bootSessionUUID: String
    public var focusedSpace: Int
    public var displayUUID: String
    public var stash: [StashEntry]
    public var originals: [UInt32: Rect]

    public init(
        instanceId: UUID,
        bootSessionUUID: String,
        focusedSpace: Int,
        displayUUID: String,
        stash: [StashEntry],
        originals: [UInt32: Rect] = [:]
    ) {
        self.instanceId = instanceId
        self.bootSessionUUID = bootSessionUUID
        self.focusedSpace = focusedSpace
        self.displayUUID = displayUUID
        self.stash = stash
        self.originals = originals
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId
        case bootSessionUUID
        case focusedSpace
        case displayUUID
        case stash
        case originals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(UUID.self, forKey: .instanceId)
        bootSessionUUID = try container.decode(String.self, forKey: .bootSessionUUID)
        focusedSpace = try container.decode(Int.self, forKey: .focusedSpace)
        displayUUID = try container.decode(String.self, forKey: .displayUUID)
        stash = try container.decode([StashEntry].self, forKey: .stash)
        originals = try container.decodeIfPresent([UInt32: Rect].self, forKey: .originals) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceId, forKey: .instanceId)
        try container.encode(bootSessionUUID, forKey: .bootSessionUUID)
        try container.encode(focusedSpace, forKey: .focusedSpace)
        try container.encode(displayUUID, forKey: .displayUUID)
        try container.encode(stash, forKey: .stash)
        try container.encode(originals, forKey: .originals)
    }

    public static func encode(_ file: SessionFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> SessionFile {
        try JSONDecoder().decode(SessionFile.self, from: data)
    }
}

/// Prefer a previously recorded pre-tiling frame; fall back to the live frame.
/// Pure so the agent can apply the persisted `originals` registry on re-adopt
/// without letting a tile rect overwrite the true original.
public func resolveOriginal(cgWindowId: UInt32, liveFrame: Rect, knownOriginals: [UInt32: Rect]) -> Rect {
    knownOriginals[cgWindowId] ?? liveFrame
}

/// A sane non-tiled frame for quit/unstash fallback. `index` cascades windows
/// so several of them do not stack exactly once they leave the tile layout.
public func cascadeRestoreRect(
    usable: Rect,
    index: Int,
    preferredWidth: Double = 1100,
    preferredHeight: Double = 700
) -> Rect {
    let w = min(preferredWidth, usable.w * 0.7)
    let h = min(preferredHeight, usable.h * 0.7)
    let step = 28.0 * Double(index % 8)
    let x = min(usable.x + 40 + step, max(usable.x, usable.maxX - w))
    let y = min(usable.y + 40 + step, max(usable.y, usable.maxY - h))
    return Rect(x: x, y: y, w: w, h: h)
}

extension Session {
    public func markStashed(space spaceId: SpaceId, ids: Set<UInt32>) -> Session {
        var session = self
        guard var space = session.spaces[spaceId] else { return session }
        for (id, var node) in space.nodes {
            if var leaf = node.leaf, ids.contains(leaf.cgWindowId) {
                leaf.role = .stashed
                node.leaf = leaf
                space.nodes[id] = node
            }
        }
        for i in space.floating.indices where ids.contains(space.floating[i].cgWindowId) {
            space.floating[i].role = .stashed
        }
        session.spaces[spaceId] = space
        return session
    }

    public func markUnstashed(space spaceId: SpaceId) -> Session {
        var session = self
        guard var space = session.spaces[spaceId] else { return session }
        for (id, var node) in space.nodes {
            if var leaf = node.leaf, leaf.role == .stashed {
                leaf.role = space.luminaFullscreen == id ? .luminaFS : .tiled
                node.leaf = leaf
                space.nodes[id] = node
            }
        }
        for i in space.floating.indices where space.floating[i].role == .stashed {
            space.floating[i].role = .floating
        }
        session.spaces[spaceId] = space
        return session
    }


    public func collectOriginals() -> [UInt32: Rect] {
        var out: [UInt32: Rect] = [:]
        for space in spaces.values {
            for node in space.tiledLeaves() {
                if let w = node.leaf, let original = w.originalFrame {
                    out[w.cgWindowId] = original
                }
            }
            for w in space.floating {
                if let original = w.originalFrame {
                    out[w.cgWindowId] = original
                }
            }
        }
        return out
    }

    public func collectStashEntries(exceptSpace: SpaceId? = nil) -> [StashEntry] {
        var out: [StashEntry] = []
        for (id, space) in spaces {
            if id == exceptSpace { continue }
            for node in space.tiledLeaves() {
                if let w = node.leaf {
                    out.append(StashEntry(cgWindowId: w.cgWindowId, pid: w.pid, bundleId: w.bundleId, lastOnscreenFrame: w.lastOnscreenFrame, originalFrame: w.originalFrame))
                }
            }
            for w in space.floating {
                out.append(StashEntry(cgWindowId: w.cgWindowId, pid: w.pid, bundleId: w.bundleId, lastOnscreenFrame: w.lastOnscreenFrame, originalFrame: w.originalFrame))
            }
        }
        return out
    }
}
