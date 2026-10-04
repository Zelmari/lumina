import Foundation

extension Session {
    /// Insert `newLeaf` as a tiled leaf using spiral with **permanent** split axes.
    ///
    /// - If `root == nil`, `newLeaf` becomes root.
    /// - Else target = focused tiled leaf if `focusedWindow` is that leaf; else `lastTiledLeaf`;
    ///   else treat as empty.
    /// - Replace target with a container: children `[old, new]`, ratio `[0.5, 0.5]`.
    /// - Axis: if replacing the root leaf, `horizontal` if `usableIsWide` else `vertical`.
    ///   Else opposite of the parent's axis.
    /// - Never recomputes axis from current W/H after the split is made.
    public func insertSpiral(
        space spaceId: SpaceId,
        newLeaf: WindowRef,
        usableIsWide: Bool
    ) -> Session {
        var session = self
        guard var space = session.spaces[spaceId] else { return session }

        var leafRef = newLeaf
        leafRef.role = .tiled

        if space.root == nil {
            let id = session.allocateNodeId()
            let node = Node(id: id, parent: nil, children: [], axis: .horizontal, ratio: [], leaf: leafRef)
            space.setNode(node)
            space.root = id
            space.focusedWindow = leafRef.cgWindowId
            space.lastTiledLeaf = id
            session.spaces[spaceId] = space
            return session
        }

        guard let targetId = space.resolveInsertTarget(),
              var old = space.nodes[targetId],
              old.isLeaf
        else {
            // A corrupt tree is left alone. Wiping `nodes` drops every tiled window.
            return session
        }

        let previousParent = old.parent
        let axis: Axis
        if previousParent == nil {
            axis = usableIsWide ? .horizontal : .vertical
        } else if let parent = space.nodes[previousParent!] {
            axis = parent.axis.opposite
        } else {
            axis = usableIsWide ? .horizontal : .vertical
        }

        let containerId = session.allocateNodeId()
        let newId = session.allocateNodeId()

        old.parent = containerId
        space.setNode(old)

        let newNode = Node(
            id: newId,
            parent: containerId,
            children: [],
            axis: .horizontal,
            ratio: [],
            leaf: leafRef
        )
        let container = Node(
            id: containerId,
            parent: previousParent,
            children: [old.id, newId],
            axis: axis,
            ratio: [0.5, 0.5],
            leaf: nil
        )
        space.setNode(newNode)
        space.setNode(container)

        if let previousParent, var parent = space.nodes[previousParent] {
            if let idx = parent.children.firstIndex(of: old.id) {
                parent.children[idx] = containerId
            }
            space.setNode(parent)
        } else {
            space.root = containerId
        }

        space.focusedWindow = leafRef.cgWindowId
        space.lastTiledLeaf = newId
        session.spaces[spaceId] = space
        return session
    }

    /// Remove a leaf. Sibling is promoted into the parent's slot (or becomes root).
    /// Last tiled leaf → `root = nil`. Space remains. Clears luminaFS if it pointed at the node.
    public func remove(space spaceId: SpaceId, node nodeId: NodeId) -> Session {
        var session = self
        guard var space = session.spaces[spaceId], let node = space.nodes[nodeId] else {
            return session
        }

        let removedWindow = node.leaf
        if space.luminaFullscreen == nodeId {
            space.luminaFullscreen = nil
        }

        if space.root == nodeId {
            space.nodes.removeValue(forKey: nodeId)
            space.root = nil
            if space.focusedWindow == removedWindow?.cgWindowId {
                space.focusedWindow = space.floating.first?.cgWindowId
            }
            if space.lastTiledLeaf == nodeId {
                space.lastTiledLeaf = nil
            }
            session.spaces[spaceId] = space
            return session
        }

        guard let parentId = node.parent, var parent = space.nodes[parentId] else {
            space.nodes.removeValue(forKey: nodeId)
            session.spaces[spaceId] = space
            return session
        }

        parent.children.removeAll { $0 == nodeId }
        space.nodes.removeValue(forKey: nodeId)

        if parent.children.count == 1, let siblingId = parent.children.first, var sibling = space.nodes[siblingId] {
            sibling.parent = parent.parent
            space.setNode(sibling)
            if let grandId = parent.parent, var grand = space.nodes[grandId] {
                if let idx = grand.children.firstIndex(of: parentId) {
                    grand.children[idx] = siblingId
                }
                space.setNode(grand)
            } else {
                space.root = siblingId
            }
            space.nodes.removeValue(forKey: parentId)
        } else if parent.children.isEmpty {
            space.nodes.removeValue(forKey: parentId)
            if space.root == parentId {
                space.root = nil
            }
        } else {
            if parent.ratio.count != parent.children.count {
                let n = Double(parent.children.count)
                parent.ratio = Array(repeating: n == 0 ? 1 : 1.0 / n, count: parent.children.count)
            }
            space.setNode(parent)
        }

        if space.lastTiledLeaf == nodeId {
            space.lastTiledLeaf = space.firstTiledLeaf()
        }
        if space.focusedWindow == removedWindow?.cgWindowId {
            if let last = space.lastTiledLeaf, let leaf = space.nodes[last]?.leaf {
                space.focusedWindow = leaf.cgWindowId
            } else {
                space.focusedWindow = space.floating.first?.cgWindowId
            }
        }
        session.spaces[spaceId] = space
        return session
    }

    public func removeWindow(space spaceId: SpaceId, cgWindowId: UInt32) -> Session {
        guard let space = spaces[spaceId] else { return self }
        if let node = space.leaf(containing: cgWindowId) {
            return remove(space: spaceId, node: node.id)
        }
        var session = self
        var s = space
        s.floating.removeAll { $0.cgWindowId == cgWindowId }
        if s.focusedWindow == cgWindowId {
            s.focusedWindow = s.floating.first?.cgWindowId ?? s.nodes[s.lastTiledLeaf ?? NodeId(raw: 0)]?.leaf?.cgWindowId
        }
        session.spaces[spaceId] = s
        return session
    }

    /// Keep the leaf/floater; replace a stale `CGWindowID` (Electron often mints a new one).
    public func rebindWindowId(space spaceId: SpaceId, from: UInt32, to: UInt32) -> Session {
        guard from != to, var space = spaces[spaceId] else { return self }
        if space.leaf(containing: to) != nil || space.floating.contains(where: { $0.cgWindowId == to }) {
            return self
        }
        var session = self
        if var node = space.leaf(containing: from), var leaf = node.leaf {
            leaf.cgWindowId = to
            node.leaf = leaf
            space.setNode(node)
            if space.focusedWindow == from { space.focusedWindow = to }
        }
        if let idx = space.floating.firstIndex(where: { $0.cgWindowId == from }) {
            space.floating[idx].cgWindowId = to
            if space.focusedWindow == from { space.focusedWindow = to }
        }
        session.spaces[spaceId] = space
        session.nativeFSWindows = session.nativeFSWindows.map { window in
            guard window.cgWindowId == from else { return window }
            var next = window
            next.cgWindowId = to
            return next
        }
        return session
    }

    /// A CGWindowID swap is a property of the window, not of whichever space
    /// happened to be focused. Rebind every space and the native-FS list.
    public func rebindWindowId(from: UInt32, to: UInt32) -> Session {
        guard from != to else { return self }
        var session = self
        for spaceId in spaces.keys {
            session = session.rebindWindowId(space: spaceId, from: from, to: to)
        }
        return session
    }

    /// Promote a floating window into the spiral tree. Used when an app's
    /// placeholder (Electron splash) was classified floating and its real
    /// window replaced the id.
    public func tileFloater(space spaceId: SpaceId, cgWindowId: UInt32, usableIsWide: Bool) -> Session {
        var session = self
        guard var space = session.spaces[spaceId],
              let idx = space.floating.firstIndex(where: { $0.cgWindowId == cgWindowId })
        else { return session }
        var window = space.floating.remove(at: idx)
        window.role = .tiled
        session.spaces[spaceId] = space
        session = session.insertSpiral(space: spaceId, newLeaf: window, usableIsWide: usableIsWide)
        if session.spaces[spaceId]?.luminaFullscreen != nil {
            session = session.markStashed(space: spaceId, ids: [window.cgWindowId])
        }
        return session
    }
}

extension Space {
    func resolveInsertTarget() -> NodeId? {
        if let focused = focusedWindow, let leaf = leaf(containing: focused), leaf.isLeaf {
            return leaf.id
        }
        if let last = lastTiledLeaf, nodes[last]?.isLeaf == true {
            return last
        }
        return firstTiledLeaf()
    }

    func firstTiledLeaf() -> NodeId? {
        guard let root else { return nil }
        return leftmostLeaf(from: root)
    }

    func leftmostLeaf(from id: NodeId) -> NodeId? {
        guard let node = nodes[id] else { return nil }
        if node.isLeaf { return id }
        guard let first = node.children.first else { return nil }
        return leftmostLeaf(from: first)
    }

    public func tiledLeaves() -> [Node] {
        nodes.values.filter { $0.isLeaf && $0.leaf != nil }.sorted { $0.id < $1.id }
    }
}
