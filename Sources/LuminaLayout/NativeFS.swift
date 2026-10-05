import Foundation

public struct NativeFSSignals: Equatable, Sendable {
    public var missingFromOnScreen: Bool
    public var pidAlive: Bool
    public var spaceChangeRecently: Bool
    public var axFullscreen: Bool
    public var skyLightIdChanged: Bool

    public init(
        missingFromOnScreen: Bool,
        pidAlive: Bool,
        spaceChangeRecently: Bool = false,
        axFullscreen: Bool = false,
        skyLightIdChanged: Bool = false
    ) {
        self.missingFromOnScreen = missingFromOnScreen
        self.pidAlive = pidAlive
        self.spaceChangeRecently = spaceChangeRecently
        self.axFullscreen = axFullscreen
        self.skyLightIdChanged = skyLightIdChanged
    }
}

/// Native fullscreen only when the window has left this display's on-screen list.
/// `AXFullScreen` without that, and without a space change, is an in-place zoom.
public func isNativeFullscreen(_ signals: NativeFSSignals) -> Bool {
    guard signals.pidAlive, signals.missingFromOnScreen else { return false }
    return signals.spaceChangeRecently || signals.axFullscreen || signals.skyLightIdChanged
}

public func bookmark(for leaf: Node, in space: Space) -> Bookmark {
    let parent = leaf.parent.flatMap { space.nodes[$0] }
    let index = parent?.children.firstIndex(of: leaf.id) ?? 0
    let sibling = parent?.children.first { $0 != leaf.id }
    return Bookmark(
        spaceId: space.id,
        parentId: leaf.parent,
        indexInParent: index,
        ratioSnapshot: parent?.ratio ?? [],
        wasFloating: false,
        siblingId: sibling,
        axis: parent?.axis ?? .horizontal
    )
}

extension Session {
    public func detachNativeFS(space spaceId: SpaceId, nodeId: NodeId) -> Session {
        var session = self
        guard let space = session.spaces[spaceId], let node = space.nodes[nodeId], var window = node.leaf else {
            return session
        }
        window.nativeFSBookmark = bookmark(for: node, in: space)
        window.role = .nativeFS
        session = session.remove(space: spaceId, node: nodeId)
        return session.rememberNativeFS(window)
    }

    public func reinsertNativeFS(_ window: WindowRef, usableIsWide: Bool) -> Session {
        var w = window
        let bookmark = w.nativeFSBookmark
        w.nativeFSBookmark = nil
        w.role = .tiled
        // Insert first: `insertSpiral` no-ops on a corrupt tree, and dropping
        // the bookmark before a failed insert would lose the window.
        let inserted: Session
        if let bookmark, spaces[bookmark.spaceId] != nil,
           let siblingId = bookmark.siblingId,
           spaces[bookmark.spaceId]?.nodes[siblingId] != nil
        {
            inserted = wrapSibling(
                spaceId: bookmark.spaceId,
                siblingId: siblingId,
                window: w,
                index: bookmark.indexInParent,
                axis: bookmark.axis,
                ratio: bookmark.ratioSnapshot
            )
        } else {
            let target = bookmark.flatMap { spaces[$0.spaceId] != nil ? $0.spaceId : nil } ?? focusedSpace
            inserted = insertSpiral(space: target, newLeaf: w, usableIsWide: usableIsWide)
        }
        guard inserted.spaceContaining(cgWindowId: w.cgWindowId) != nil else {
            return self
        }
        var session = inserted
        session.nativeFSWindows.removeAll { $0.cgWindowId == window.cgWindowId }
        return session
    }

    /// Put `window` back beside `siblingId`, which `remove` promoted into the old parent's slot.
    private func wrapSibling(
        spaceId: SpaceId,
        siblingId: NodeId,
        window: WindowRef,
        index: Int,
        axis: Axis,
        ratio: [Double]
    ) -> Session {
        var session = self
        guard var space = session.spaces[spaceId], var sibling = space.nodes[siblingId] else {
            return session.insertSpiral(space: spaceId, newLeaf: window, usableIsWide: true)
        }
        let previousParent = sibling.parent
        let containerId = session.allocateNodeId()
        let newId = session.allocateNodeId()
        sibling.parent = containerId
        space.setNode(sibling)
        let newNode = Node(
            id: newId,
            parent: containerId,
            children: [],
            axis: .horizontal,
            ratio: [],
            leaf: window
        )
        let ratios = ratio.count == 2 ? ratio : [0.5, 0.5]
        let children = index == 0 ? [newId, siblingId] : [siblingId, newId]
        let container = Node(
            id: containerId,
            parent: previousParent,
            children: children,
            axis: axis,
            ratio: ratios,
            leaf: nil
        )
        space.setNode(newNode)
        space.setNode(container)
        if let previousParent, var parent = space.nodes[previousParent] {
            if let idx = parent.children.firstIndex(of: siblingId) {
                parent.children[idx] = containerId
            }
            space.setNode(parent)
        } else {
            space.root = containerId
        }
        space.focusedWindow = window.cgWindowId
        space.lastTiledLeaf = newId
        session.spaces[spaceId] = space
        return session
    }

    private func rememberNativeFS(_ window: WindowRef) -> Session {
        var session = self
        session.nativeFSWindows.append(window)
        return session
    }
}
