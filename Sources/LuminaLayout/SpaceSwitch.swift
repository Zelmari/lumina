import Foundation

extension Session {
    public func switchTo(_ id: SpaceId) -> Session {
        guard spaces[id] != nil else { return self }
        if focusedSpace == id { return self }
        var session = markStashed(
            space: focusedSpace,
            ids: Set(visibleIds(on: focusedSpace))
        )
        session = session.markUnstashed(space: id)
        session.focusedSpace = id
        return session
    }

    public func workspacePrev() -> Session {
        let next = focusedSpace.raw == 1 ? spaceCount : focusedSpace.raw - 1
        return switchTo(SpaceId.require(next))
    }

    public func workspaceNext() -> Session {
        let next = focusedSpace.raw == spaceCount ? 1 : focusedSpace.raw + 1
        return switchTo(SpaceId.require(next))
    }

    /// Take focused window; if luminaFS, drop it on source; insert as tile on dest; follow.
    public func moveNodeToWorkspace(_ destId: SpaceId, usableIsWide: Bool) -> Session {
        guard spaces[destId] != nil else { return self }
        if destId == focusedSpace { return self }
        guard let space = spaces[focusedSpace], let focused = space.focusedWindow else { return self }

        let window: WindowRef?
        if let leaf = space.leaf(containing: focused), let w = leaf.leaf {
            window = w
        } else if let idx = space.floating.firstIndex(where: { $0.cgWindowId == focused }) {
            window = space.floating[idx]
        } else {
            window = nil
        }
        guard var moving = window else { return self }
        moving.role = .tiled

        // Insert into the destination first, on this copy. `insertSpiral` no-ops
        // on a corrupt tree; removing from the source first would lose the window.
        var session = insertSpiral(space: destId, newLeaf: moving, usableIsWide: usableIsWide)
        guard session.visibleIds(on: destId).contains(moving.cgWindowId) else {
            return self
        }

        if space.luminaFullscreen != nil {
            session = session.exitLuminaFS(space: focusedSpace)
        }
        guard let src = session.spaces[session.focusedSpace] else { return session }
        if let leaf = src.leaf(containing: focused) {
            session = session.remove(space: session.focusedSpace, node: leaf.id)
        } else if let idx = src.floating.firstIndex(where: { $0.cgWindowId == focused }) {
            var s = session.spaces[session.focusedSpace]!
            s.floating.remove(at: idx)
            session.spaces[session.focusedSpace] = s
        }

        session = session.switchTo(destId)
        // `switchTo` unstashes the destination; a window arriving on a space
        // with active luminaFS must stay parked like any other new tiled leaf,
        // and focus must stay on the fullscreen window.
        if let fullscreen = session.spaces[destId]?.luminaFullscreen {
            session = session.markStashed(space: destId, ids: [moving.cgWindowId])
            if var dest = session.spaces[destId] {
                dest.focusedWindow = dest.nodes[fullscreen]?.leaf?.cgWindowId
                dest.lastTiledLeaf = fullscreen
                session.spaces[destId] = dest
            }
        }
        return session
    }

    public func floatToggle(space spaceId: SpaceId, usableIsWide: Bool) -> Session {
        guard let space = spaces[spaceId], let focused = space.focusedWindow else { return self }
        if let leaf = space.leaf(containing: focused) {
            var session = self
            if space.luminaFullscreen == leaf.id {
                session = session.exitLuminaFS(space: spaceId)
            }
            return session.floatLeaf(space: spaceId, nodeId: leaf.id).0
        }
        if let idx = space.floating.firstIndex(where: { $0.cgWindowId == focused }) {
            var session = self
            var s = space
            var w = s.floating.remove(at: idx)
            session.spaces[spaceId] = s
            w.role = .tiled
            session = session.insertSpiral(space: spaceId, newLeaf: w, usableIsWide: usableIsWide)
            if session.spaces[spaceId]?.luminaFullscreen != nil {
                session = session.markStashed(space: spaceId, ids: [w.cgWindowId])
            }
            return session
        }
        return self
    }

    public func visibleIds(on spaceId: SpaceId) -> [UInt32] {
        guard let space = spaces[spaceId] else { return [] }
        let tiled = space.tiledLeaves().compactMap { $0.leaf?.cgWindowId }
        let floating = space.floating.map(\.cgWindowId)
        return tiled + floating
    }

    public func spaceContaining(cgWindowId: UInt32) -> SpaceId? {
        for (id, space) in spaces {
            if space.leaf(containing: cgWindowId) != nil { return id }
            if space.floating.contains(where: { $0.cgWindowId == cgWindowId }) { return id }
        }
        return nil
    }

    public var allWindowIds: Set<UInt32> {
        Set(spaces.keys.flatMap { visibleIds(on: $0) })
    }
}

public func wrapWorkspace(current: Int, count: Int, delta: Int) -> Int {
    guard count > 0 else { return 1 }
    let shifted = ((current - 1 + delta) % count + count) % count
    return shifted + 1
}

extension Space {
    /// Window to focus when arriving on this space: the recorded focus when it
    /// still lives here, else the fullscreen leaf, else the last tiled leaf,
    /// else the first tiled leaf, else the first floater. Nil when empty.
    /// The agent moves the windows on screen with AX but macOS does not focus
    /// them, so the agent raises and focuses the candidate explicitly.
    public func focusRestorationCandidate() -> UInt32? {
        // Never restore focus to a parked window: nativeFocus would refuse it
        // and the space would come back without keyboard focus.
        if let focused = focusedWindow, let focusedRole = role(of: focused), focusedRole != .stashed {
            return focused
        }
        if let fs = luminaFullscreen, let w = nodes[fs]?.leaf?.cgWindowId {
            return w
        }
        if let last = lastTiledLeaf, let leaf = nodes[last]?.leaf, leaf.role != .stashed {
            return leaf.cgWindowId
        }
        if let w = tiledLeaves().first(where: { $0.leaf?.role != .stashed })?.leaf?.cgWindowId {
            return w
        }
        return floating.first(where: { $0.role != .stashed })?.cgWindowId
    }

    private func role(of cgWindowId: UInt32) -> WindowRole? {
        if let w = leaf(containing: cgWindowId)?.leaf { return w.role }
        return floating.first(where: { $0.cgWindowId == cgWindowId })?.role
    }
}
