import Foundation

/// Monotonic id allocated by `Session`. Stable in tests (starts at 1).
public struct NodeId: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    public static func < (lhs: NodeId, rhs: NodeId) -> Bool {
        lhs.raw < rhs.raw
    }

    public var description: String { "n\(raw)" }
}

/// Lumina space 1…10. Key `0` maps to 10 only at the bind/CLI layer, not here.
public struct SpaceId: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let raw: Int

    public static let min = 1
    public static let max = 10

    public init?(raw: Int) {
        guard (Self.min...Self.max).contains(raw) else { return nil }
        self.raw = raw
    }

    public static func make(_ raw: Int) -> SpaceId? {
        SpaceId(raw: raw)
    }

    /// Debug-only trap for programmer error. Prefer `make`.
    public static func require(_ raw: Int) -> SpaceId {
        guard let id = SpaceId(raw: raw) else {
            preconditionFailure("SpaceId must be 1...10, got \(raw)")
        }
        return id
    }

    public static func < (lhs: SpaceId, rhs: SpaceId) -> Bool {
        lhs.raw < rhs.raw
    }

    public var description: String { "\(raw)" }
}

public enum Axis: String, Equatable, Sendable, Codable {
    case horizontal
    case vertical

    public var opposite: Axis {
        self == .horizontal ? .vertical : .horizontal
    }
}

public enum Direction: String, Equatable, Sendable, Codable {
    case left
    case down
    case up
    case right
}

public struct Gaps: Equatable, Hashable, Sendable, Codable {
    public var inner: Int
    public var outer: Int

    public init(inner: Int, outer: Int) {
        self.inner = inner
        self.outer = outer
    }

    public static let `default` = Gaps(inner: 8, outer: 8)
}

public enum WindowRole: String, Equatable, Sendable, Codable {
    case tiled
    case floating
    case stashed
    case nativeFS
    case luminaFS
    case ignored
}

public struct Bookmark: Equatable, Sendable, Codable {
    public var spaceId: SpaceId
    public var parentId: NodeId?
    public var indexInParent: Int
    public var ratioSnapshot: [Double]
    public var wasFloating: Bool
    /// The other child of the split. `remove` promotes this node and deletes the parent,
    /// so reinsert wraps this sibling rather than looking up `parentId`.
    public var siblingId: NodeId?
    public var axis: Axis

    public init(
        spaceId: SpaceId,
        parentId: NodeId?,
        indexInParent: Int,
        ratioSnapshot: [Double],
        wasFloating: Bool,
        siblingId: NodeId? = nil,
        axis: Axis = .horizontal
    ) {
        self.spaceId = spaceId
        self.parentId = parentId
        self.indexInParent = indexInParent
        self.ratioSnapshot = ratioSnapshot
        self.wasFloating = wasFloating
        self.siblingId = siblingId
        self.axis = axis
    }
}

public struct WindowRef: Equatable, Sendable, Codable {
    /// `CGWindowID` is `UInt32`. No CoreGraphics in this module.
    public var cgWindowId: UInt32
    public var pid: Int32
    public var bundleId: String?
    public var role: WindowRole
    public var lastOnscreenFrame: Rect
    /// Frame before Lumina first managed the window. Never overwritten by
    /// tiling, so quitting can put windows back where the user had them.
    /// Nil for windows born while already managed.
    public var originalFrame: Rect?
    public var nativeFSBookmark: Bookmark?
    /// Starts at 0. Agent increments on own setFrame / stash / unstash.
    public var generation: UInt64

    public init(
        cgWindowId: UInt32,
        pid: Int32,
        bundleId: String? = nil,
        role: WindowRole = .tiled,
        lastOnscreenFrame: Rect = Rect(x: 0, y: 0, w: 0, h: 0),
        originalFrame: Rect? = nil,
        nativeFSBookmark: Bookmark? = nil,
        generation: UInt64 = 0
    ) {
        self.cgWindowId = cgWindowId
        self.pid = pid
        self.bundleId = bundleId
        self.role = role
        self.lastOnscreenFrame = lastOnscreenFrame
        self.originalFrame = originalFrame
        self.nativeFSBookmark = nativeFSBookmark
        self.generation = generation
    }
}

/// Binary spiral in v1 always produces 2 children. n-ary is allowed in the type.
/// Invariant: `leaf != nil` only if `children.isEmpty`.
public struct Node: Equatable, Sendable, Codable {
    public var id: NodeId
    public var parent: NodeId?
    public var children: [NodeId]
    public var axis: Axis
    public var ratio: [Double]
    public var leaf: WindowRef?

    public init(
        id: NodeId,
        parent: NodeId? = nil,
        children: [NodeId] = [],
        axis: Axis = .horizontal,
        ratio: [Double] = [],
        leaf: WindowRef? = nil
    ) {
        self.id = id
        self.parent = parent
        self.children = children
        self.axis = axis
        self.ratio = ratio
        self.leaf = leaf
    }

    public var isLeaf: Bool { children.isEmpty }
}

public struct Space: Equatable, Sendable, Codable {
    public var id: SpaceId
    /// Tiled leaf or floater on this space; nil if none.
    public var focusedWindow: UInt32?
    /// Last focused tiled leaf; used when focus is a floater.
    public var lastTiledLeaf: NodeId?
    /// nil = empty tiled tree (space still exists).
    public var root: NodeId?
    /// Not in the tree; not in `frames()`.
    public var floating: [WindowRef]
    /// At most one; points at a tiled leaf.
    public var luminaFullscreen: NodeId?
    public var lastDisplayFrame: Rect?
    public var nodes: [NodeId: Node]

    public init(
        id: SpaceId,
        focusedWindow: UInt32? = nil,
        lastTiledLeaf: NodeId? = nil,
        root: NodeId? = nil,
        floating: [WindowRef] = [],
        luminaFullscreen: NodeId? = nil,
        lastDisplayFrame: Rect? = nil,
        nodes: [NodeId: Node] = [:]
    ) {
        self.id = id
        self.focusedWindow = focusedWindow
        self.lastTiledLeaf = lastTiledLeaf
        self.root = root
        self.floating = floating
        self.luminaFullscreen = luminaFullscreen
        self.lastDisplayFrame = lastDisplayFrame
        self.nodes = nodes
    }

    public func node(_ id: NodeId) -> Node? {
        nodes[id]
    }

    public func leaf(containing cgWindowId: UInt32) -> Node? {
        nodes.values.first { $0.leaf?.cgWindowId == cgWindowId }
    }

    public mutating func setNode(_ node: Node) {
        nodes[node.id] = node
    }
}

public struct Session: Equatable, Sendable, Codable {
    public var instanceId: UUID
    /// Alias of `instanceId`.
    public var nativeSpaceToken: UUID
    public var spaceCount: Int
    public var focusedSpace: SpaceId
    public var spaces: [SpaceId: Space]
    /// pause == enable off; RAM only; never written to session.json.
    public var paused: Bool
    /// Next monotonic NodeId. Starts at 1.
    public var nextNodeId: UInt64
    /// Native-FS bookmarks live in RAM only, not session.json.
    public var nativeFSWindows: [WindowRef]

    public init(
        instanceId: UUID,
        nativeSpaceToken: UUID? = nil,
        spaceCount: Int,
        focusedSpace: SpaceId,
        spaces: [SpaceId: Space],
        paused: Bool = false,
        nextNodeId: UInt64 = 1,
        nativeFSWindows: [WindowRef] = []
    ) {
        self.instanceId = instanceId
        self.nativeSpaceToken = nativeSpaceToken ?? instanceId
        self.spaceCount = spaceCount
        self.focusedSpace = focusedSpace
        self.spaces = spaces
        self.paused = paused
        self.nextNodeId = nextNodeId
        self.nativeFSWindows = nativeFSWindows
    }

    /// Builds spaces `1...count`, `focusedSpace = 1`, all `root == nil`, `paused = false`.
    public static func empty(spaceCount: Int, instanceId: UUID = UUID()) -> Session {
        let count = min(max(spaceCount, 1), 10)
        var spaces: [SpaceId: Space] = [:]
        for i in 1...count {
            let id = SpaceId.require(i)
            spaces[id] = Space(id: id)
        }
        return Session(
            instanceId: instanceId,
            nativeSpaceToken: instanceId,
            spaceCount: count,
            focusedSpace: SpaceId.require(1),
            spaces: spaces,
            paused: false,
            nextNodeId: 1
        )
    }

    public mutating func allocateNodeId() -> NodeId {
        let id = NodeId(raw: nextNodeId)
        nextNodeId += 1
        return id
    }

    public subscript(spaceId: SpaceId) -> Space? {
        get { spaces[spaceId] }
        set { spaces[spaceId] = newValue }
    }

    public var current: Space {
        get { spaces[focusedSpace] ?? Space(id: focusedSpace) }
        set { spaces[focusedSpace] = newValue }
    }
}
