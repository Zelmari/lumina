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

/// If unsure a new native Space appeared, do **not** take the native-FS path.
public func isNativeFullscreen(_ signals: NativeFSSignals) -> Bool {
    guard signals.pidAlive else { return false }
    let leftDisplay = signals.missingFromOnScreen || signals.axFullscreen
    guard leftDisplay else { return false }
    return signals.spaceChangeRecently || signals.axFullscreen || signals.skyLightIdChanged
}

public func bookmark(for leaf: Node, in space: Space) -> Bookmark {
    Bookmark(
        spaceId: space.id,
        parentId: leaf.parent,
        indexInParent: leaf.parent.flatMap { space.nodes[$0]?.children.firstIndex(of: leaf.id) } ?? 0,
        ratioSnapshot: leaf.parent.flatMap { space.nodes[$0]?.ratio } ?? [],
        wasFloating: false
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
        guard let bookmark = w.nativeFSBookmark, let space = spaces[bookmark.spaceId] else {
            w.nativeFSBookmark = nil
            w.role = .tiled
            return insertSpiral(space: focusedSpace, newLeaf: w, usableIsWide: usableIsWide)
        }
        w.nativeFSBookmark = nil
        w.role = .tiled
        if let parentId = bookmark.parentId,
           let parent = space.nodes[parentId],
           parent.children.count > bookmark.indexInParent
        {
            // Sibling still there: insert at the remembered index by splitting that slot's sibling? Spec:
            // put back in that slot; sibling gone → insert at focus.
            // If parent still exists, restore as sibling of whoever is in that slot by replacing empty hole —
            // after detach, sibling was promoted so parent is gone. That's "sibling gone" if the container collapsed.
            return insertSpiral(space: bookmark.spaceId, newLeaf: w, usableIsWide: usableIsWide)
        }
        if space.root == nil {
            return insertSpiral(space: bookmark.spaceId, newLeaf: w, usableIsWide: usableIsWide)
        }
        return insertSpiral(space: bookmark.spaceId, newLeaf: w, usableIsWide: usableIsWide)
    }

    private func rememberNativeFS(_ window: WindowRef) -> Session {
        var session = self
        session.nativeFSWindows.append(window)
        return session
    }
}
