import Foundation

public struct SpatialWindow: Equatable, Sendable {
    public var id: NodeId?
    public var role: SpatialRole
    public var frame: Rect
    public var cgWindowId: UInt32

    public init(id: NodeId? = nil, role: SpatialRole, frame: Rect, cgWindowId: UInt32) {
        self.id = id
        self.role = role
        self.frame = frame
        self.cgWindowId = cgWindowId
    }
}

public enum SpatialRole: Equatable, Sendable {
    case tiled
    case floating
}

public func focusSpatial(windows: [SpatialWindow], from: SpatialWindow, dir: Direction) -> SpatialWindow? {
    let tiled = windows.filter { $0.cgWindowId != from.cgWindowId && $0.role == .tiled }
    let floating = windows.filter { $0.cgWindowId != from.cgWindowId && $0.role == .floating }
    let tiledInStrip = tiled.filter { inHalfPlane($0, from: from, dir: dir, useCenter: false) && inStrip($0, from: from, dir: dir) }
    let tiledEligible = tiled.filter { candidate in
        guard inHalfPlane(candidate, from: from, dir: dir, useCenter: false) else { return false }
        return inStrip(candidate, from: from, dir: dir) || tiledInStrip.isEmpty
    }
    let floatingEligible = floating.filter { inHalfPlane($0, from: from, dir: dir, useCenter: true) }
    // Tiled-in-strip outranks floaters even if a floater center is nearer (design §18).
    let eligible = tiledInStrip.isEmpty ? (tiledEligible + floatingEligible) : tiledInStrip
    guard !eligible.isEmpty else { return nil }
    let origin = from.frame.center
    return eligible.min { a, b in
        let da = a.frame.center.distance(to: origin)
        let db = b.frame.center.distance(to: origin)
        if da != db { return da < db }
        return a.cgWindowId < b.cgWindowId
    }
}

func inHalfPlane(_ c: SpatialWindow, from f: SpatialWindow, dir: Direction, useCenter: Bool) -> Bool {
    let origin = f.frame.center
    switch dir {
    case .left:
        let x = useCenter ? c.frame.center.x : c.frame.minX
        return x < origin.x
    case .right:
        let x = useCenter ? c.frame.center.x : c.frame.maxX
        return x > origin.x
    case .up:
        let y = useCenter ? c.frame.center.y : c.frame.minY
        return y < origin.y
    case .down:
        let y = useCenter ? c.frame.center.y : c.frame.maxY
        return y > origin.y
    }
}

func inStrip(_ c: SpatialWindow, from f: SpatialWindow, dir: Direction) -> Bool {
    switch dir {
    case .left, .right:
        return c.frame.minY < f.frame.maxY && c.frame.maxY > f.frame.minY
    case .up, .down:
        return c.frame.minX < f.frame.maxX && c.frame.maxX > f.frame.minX
    }
}

extension Session {
    /// Three swap cases. Candidates: tiled or floating, not stashed/ignored/nativeFS.
    public func swap(space spaceId: SpaceId, a: UInt32, b: UInt32) -> Session {
        var session = self
        guard var space = session.spaces[spaceId] else { return session }
        let aLeaf = space.leaf(containing: a)
        let bLeaf = space.leaf(containing: b)
        let aFloat = space.floating.firstIndex(where: { $0.cgWindowId == a })
        let bFloat = space.floating.firstIndex(where: { $0.cgWindowId == b })

        if let aNode = aLeaf, let bNode = bLeaf, var an = space.nodes[aNode.id], var bn = space.nodes[bNode.id] {
            let tmp = an.leaf
            an.leaf = bn.leaf
            bn.leaf = tmp
            space.setNode(an)
            space.setNode(bn)
            session.spaces[spaceId] = space
            return session
        }

        if let aNode = aLeaf, let bIdx = bFloat {
            exchangeTileFloater(space: &space, tile: aNode.id, floaterIndex: bIdx)
            session.spaces[spaceId] = space
            return session
        }
        if let bNode = bLeaf, let aIdx = aFloat {
            exchangeTileFloater(space: &space, tile: bNode.id, floaterIndex: aIdx)
            session.spaces[spaceId] = space
            return session
        }

        if let aIdx = aFloat, let bIdx = bFloat {
            var fa = space.floating[aIdx]
            var fb = space.floating[bIdx]
            Swift.swap(&fa.lastOnscreenFrame, &fb.lastOnscreenFrame)
            space.floating[aIdx] = fa
            space.floating[bIdx] = fb
            session.spaces[spaceId] = space
            return session
        }
        return session
    }
}

private func exchangeTileFloater(space: inout Space, tile: NodeId, floaterIndex: Int) {
    guard var node = space.nodes[tile], var oldLeaf = node.leaf else { return }
    var floater = space.floating.remove(at: floaterIndex)
    // The displaced tiled window takes the floater's old position; the caller
    // pushes that frame to AX. Leaving its own tile frame here left both
    // windows stacked exactly on top of each other.
    let floaterFrame = floater.lastOnscreenFrame
    floater.role = .tiled
    oldLeaf.role = .floating
    oldLeaf.lastOnscreenFrame = floaterFrame
    node.leaf = floater
    space.setNode(node)
    space.floating.append(oldLeaf)
}
