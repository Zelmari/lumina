import Foundation

public struct DisplayFrame: Equatable, Sendable {
    public var axFrame: Rect
    public var axVisibleFrame: Rect

    public init(axFrame: Rect, axVisibleFrame: Rect) {
        self.axFrame = axFrame
        self.axVisibleFrame = axVisibleFrame
    }
}

/// 1px vertical sliver in a bottom corner of the bound display, still inside `axFrame`.
public func stashFrame(for lastHeight: Double, display: DisplayFrame, dockRight: Bool) -> Rect {
    let height = max(lastHeight, 8)
    let y = display.axFrame.maxY - height
    let x: Double
    if dockRight {
        x = display.axFrame.minX
    } else {
        x = display.axFrame.maxX - 1
    }
    let rect = Rect(x: x, y: y, w: 1, h: height)
    let minX = max(rect.minX, display.axFrame.minX)
    let maxX = min(rect.maxX, display.axFrame.maxX)
    let minY = max(rect.minY, display.axFrame.minY)
    let maxY = min(rect.maxY, display.axFrame.maxY)
    return Rect(x: minX, y: minY, w: max(1, maxX - minX), h: max(8, maxY - minY))
}

public func isSliver(_ rect: Rect) -> Bool {
    rect.w <= 2 || rect.h <= 2
}

public struct StashEntry: Equatable, Sendable, Codable {
    public var cgWindowId: UInt32
    public var pid: Int32
    public var bundleId: String?
    public var lastOnscreenFrame: Rect

    public init(cgWindowId: UInt32, pid: Int32, bundleId: String?, lastOnscreenFrame: Rect) {
        self.cgWindowId = cgWindowId
        self.pid = pid
        self.bundleId = bundleId
        self.lastOnscreenFrame = lastOnscreenFrame
    }
}

/// On-disk session. Does not persist paused, tree, ratios, or bookmarks.
public struct SessionFile: Equatable, Sendable, Codable {
    public var instanceId: UUID
    public var bootSessionUUID: String
    public var focusedSpace: Int
    public var displayUUID: String
    public var stash: [StashEntry]

    public init(
        instanceId: UUID,
        bootSessionUUID: String,
        focusedSpace: Int,
        displayUUID: String,
        stash: [StashEntry]
    ) {
        self.instanceId = instanceId
        self.bootSessionUUID = bootSessionUUID
        self.focusedSpace = focusedSpace
        self.displayUUID = displayUUID
        self.stash = stash
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

    public func collectStashEntries(exceptSpace: SpaceId? = nil) -> [StashEntry] {
        var out: [StashEntry] = []
        for (id, space) in spaces {
            if id == exceptSpace { continue }
            for node in space.tiledLeaves() {
                if let w = node.leaf {
                    out.append(StashEntry(cgWindowId: w.cgWindowId, pid: w.pid, bundleId: w.bundleId, lastOnscreenFrame: w.lastOnscreenFrame))
                }
            }
            for w in space.floating {
                out.append(StashEntry(cgWindowId: w.cgWindowId, pid: w.pid, bundleId: w.bundleId, lastOnscreenFrame: w.lastOnscreenFrame))
            }
        }
        return out
    }
}
