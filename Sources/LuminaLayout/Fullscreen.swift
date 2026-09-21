import Foundation

public let fillSlop: Double = 12
public let fillAreaRatio: Double = 0.92

public func isFill(frame: Rect, usable: Rect) -> Bool {
    let edgesOK =
        abs(frame.minX - usable.minX) <= fillSlop
        && abs(frame.maxX - usable.maxX) <= fillSlop
        && abs(frame.minY - usable.minY) <= fillSlop
        && abs(frame.maxY - usable.maxY) <= fillSlop
    guard edgesOK else { return false }
    let inter = frame.intersection(usable)
    guard usable.area > 0 else { return false }
    return inter.area / usable.area >= fillAreaRatio
}

public enum InPlaceResize: Equatable, Sendable {
    case fill
    case halfQuarter
    case fight
}

public func classifyInPlaceResize(frame: Rect, usable: Rect) -> InPlaceResize {
    if isFill(frame: frame, usable: usable) { return .fill }
    if isHalfOrQuarter(frame: frame, usable: usable) { return .halfQuarter }
    return .fight
}

public func isHalfOrQuarter(frame: Rect, usable: Rect) -> Bool {
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= fillSlop }
    return near(frame.w, usable.w / 2)
        || near(frame.w, usable.w / 4)
        || near(frame.h, usable.h / 2)
        || near(frame.h, usable.h / 4)
}

extension Session {
    public func enterLuminaFS(space spaceId: SpaceId, leaf: NodeId) -> Session {
        var session = self
        guard var space = session.spaces[spaceId],
              space.nodes[leaf]?.isLeaf == true,
              space.nodes[leaf]?.leaf != nil
        else { return session }
        if space.luminaFullscreen != nil { return session }
        space.luminaFullscreen = leaf
        if var node = space.nodes[leaf], var w = node.leaf {
            w.role = .luminaFS
            node.leaf = w
            space.nodes[leaf] = node
        }
        session.spaces[spaceId] = space
        let others = Set(session.visibleIds(on: spaceId).filter { id in
            session.spaces[spaceId]?.nodes[leaf]?.leaf?.cgWindowId != id
        })
        return session.markStashed(space: spaceId, ids: others)
    }

    public func exitLuminaFS(space spaceId: SpaceId) -> Session {
        var session = self
        guard var space = session.spaces[spaceId], let fs = space.luminaFullscreen else {
            return session
        }
        if var node = space.nodes[fs], var w = node.leaf {
            w.role = .tiled
            node.leaf = w
            space.nodes[fs] = node
        }
        space.luminaFullscreen = nil
        session.spaces[spaceId] = space
        return session.markUnstashed(space: spaceId)
    }

    public func toggleLuminaFS(space spaceId: SpaceId) -> Session {
        guard let space = spaces[spaceId] else { return self }
        if space.luminaFullscreen != nil {
            guard let focused = space.focusedWindow,
                  space.nodes[space.luminaFullscreen!]?.leaf?.cgWindowId == focused
            else { return self }
            return exitLuminaFS(space: spaceId)
        }
        if let focused = space.focusedWindow, let leaf = space.leaf(containing: focused) {
            return enterLuminaFS(space: spaceId, leaf: leaf.id)
        }
        return self
    }

    /// New tiled id appears in tree and is stashed while luminaFS is on.
    public func insertWhileLuminaFS(space spaceId: SpaceId, window: WindowRef, result: ClassifyResult, usableIsWide: Bool) -> Session {
        switch result {
        case .unmanaged, .ignored:
            return self
        case .floating:
            var session = self
            var space = session.spaces[spaceId] ?? Space(id: spaceId)
            var w = window
            w.role = .floating
            space.floating.append(w)
            session.spaces[spaceId] = space
            return session
        case .tiled:
            let fullscreenId = spaces[spaceId]?.luminaFullscreen
            let fullscreenWindow = fullscreenId.flatMap { spaces[spaceId]?.nodes[$0]?.leaf?.cgWindowId }
            var session = insertSpiral(space: spaceId, newLeaf: window, usableIsWide: usableIsWide)
            if let space = session.spaces[spaceId], space.luminaFullscreen != nil,
               let newId = space.lastTiledLeaf
            {
                let newWindow = space.nodes[newId]?.leaf?.cgWindowId
                session = session.markStashed(
                    space: spaceId,
                    ids: Set([newWindow].compactMap { $0 })
                )
                if var space = session.spaces[spaceId] {
                    if let fullscreenWindow { space.focusedWindow = fullscreenWindow }
                    if let fullscreenId { space.lastTiledLeaf = fullscreenId }
                    session.spaces[spaceId] = space
                }
            }
            return session
        }
    }

    public func closeFocused(space spaceId: SpaceId) -> Session {
        guard let focused = spaces[spaceId]?.focusedWindow else { return self }
        return closeWindow(space: spaceId, cgWindowId: focused)
    }

    /// Close a specific window. The fullscreen leaf is this id, not whoever is focused.
    public func closeWindow(space spaceId: SpaceId, cgWindowId: UInt32) -> Session {
        guard let space = spaces[spaceId] else { return self }
        if let fs = space.luminaFullscreen, space.nodes[fs]?.leaf?.cgWindowId == cgWindowId {
            let cleared = exitLuminaFS(space: spaceId)
            if let leaf = cleared.spaces[spaceId]?.leaf(containing: cgWindowId) {
                return cleared.remove(space: spaceId, node: leaf.id)
            }
            return cleared
        }
        if let leaf = space.leaf(containing: cgWindowId) {
            return remove(space: spaceId, node: leaf.id)
        }
        return removeWindow(space: spaceId, cgWindowId: cgWindowId)
    }
}
