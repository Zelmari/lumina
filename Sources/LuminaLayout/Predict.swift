import Foundation

extension Session {
    /// The rect `insertSpiral` would give a new leaf, computed on a copy so the
    /// live session is untouched. Nil when the window would be stashed
    /// (lumina-fullscreen), immediately floated by `clampOverflow`, or the
    /// space/tree cannot take a tiled leaf.
    ///
    /// Used by the agent to write a new window straight to its tile before the
    /// real adoption pass runs; the pass then finds the frame already correct.
    public func predictedTile(
        space spaceId: SpaceId,
        window: WindowRef,
        usable: Rect,
        gaps: Gaps,
        usableIsWide: Bool,
        minSizes: [UInt32: Size] = [:]
    ) -> Rect? {
        guard let space = spaces[spaceId], space.luminaFullscreen == nil else { return nil }
        var leaf = window
        leaf.role = .tiled
        let inserted = insertSpiral(space: spaceId, newLeaf: leaf, usableIsWide: usableIsWide)
        guard let node = inserted.spaces[spaceId]?.leaf(containing: window.cgWindowId) else { return nil }
        let (clamped, floated) = inserted.clampOverflow(
            space: spaceId,
            minSizes: minSizes,
            usable: usable,
            gaps: gaps,
            preferFloat: inserted.spaces[spaceId]?.lastTiledLeaf
        )
        if floated.contains(where: { $0.cgWindowId == window.cgWindowId }) { return nil }
        guard let final = clamped.spaces[spaceId] else { return nil }
        return frames(space: final, usable: usable, gaps: gaps)[node.id]
    }
}
